#!/bin/bash

usage() {
  echo "
Supported formats: .mkv .avi .mp4 .mov .wmv .flv
This script re-encodes video files using hardware-accelerated HEVC (H.265) compression,
optionally skipping already optimized files and ignoring small files.

Usage:
  ./script.sh [-R] [min=X] [test=Y] [--dry-run] [--keep-original] [--allow-h265] [--allow-av1] [-backup /path] <folder>
    -R              : Encode recursively inside subfolders
    min=X.YZ        : Ignore files smaller than X.YZ GB
    --regex="PATTERN"        Only include files matching the given regex pattern (e.g., --regex="\.avi$").
    test=N          : Use N seconds for the test encode (default: 5)
    --dry-run       : Only show compatible files without encoding
    --keep-original : Keep original files instead of replacing them
    --allow-h265    : Allow files already encoded in H.265
    --allow-av1     : Allow files already encoded in AV1
    -backup /path   : Save original files to backup path (used only if not using --keep-original)
    --clean         : Remove temporary encoding files (.tmp_encode_*, .tmp_encode_test_*) from the folder(s, if combined with -R) 
    --purge         : Remove encoded.list files (.tmp_encode_*, .tmp_encode_test_*) from the folder(s, if combined with -R) 
    -h              : Show this help message
    --stop-after HH.5  : Stop after HH.5 hours of encoding (useful if in cron)"
  exit 0
}



# ===========================
# User Configuration Section
# ===========================

# Enable hardware acceleration (true/false)
# true  = use GPU for decoding/encoding (faster, lower CPU usage)
# false = use CPU only (slower, but more widely supported)
USE_HWACCEL=true

# Hardware acceleration type
# Common options:
# - "cuda"  = NVIDIA GPUs (NVENC)
# - "vaapi" = Intel/AMD GPUs on Linux
# - "qsv"   = Intel QuickSync Video
HWACCEL_TYPE="cuda"

# Video codec to use for encoding
# Options:
# - "hevc_nvenc"  = H.265 with NVIDIA NVENC (requires CUDA)
# - "libx265"     = H.265 via CPU
# - "hevc_vaapi"  = H.265 via VAAPI (hardware, Linux)
# - "hevc_qsv"    = H.265 via Intel QuickSync (hardware)
VIDEO_CODEC="hevc_nvenc"

# Audio codec to use
# Most compatible option: "aac"
AUDIO_CODEC="aac"

# Target audio bitrate
# Recommended: 128k (good), 192k (better), 256k+ (high quality)
AUDIO_BITRATE="256k"

# Constant quality factor for video (0–51)
# Lower = better quality, bigger file
# Higher = lower quality, smaller file
# - NVENC recommended range: 19–28
# - libx265 recommended range: 18–28
# Adaptive CQ settings based on video resolution
CQ_HD="30"           # For HD videos (resolution >= CQ_WIDTH_THRESHOLD)
CQ_SD="26"           # For SD videos (resolution < CQ_WIDTH_THRESHOLD)
CQ_WIDTH_THRESHOLD=1900  # WIDTH threshold in pixels to determine HD vs SD
#
CQ="30"
# Width cheatsheet
# Height	Width	CQ range
# 480p	     720	26–28
# 720p   	1280	28–30
# 1080p	    1920	30–32
# 2K (DCI)	2048	30–32
# 4K (UHD)	3840	32–34

# Encoding preset — affects speed and compression efficiency
# ⚠️ Available values depend on the selected VIDEO_CODEC

# For hevc_nvenc (NVIDIA):
#   "p1" = slowest, best quality
#   "p2"
#   "p3" = balanced (default)
#   "p4"
#   "p5"
#   "p6"
#   "p7" = fastest, lower quality

# For libx265 (CPU encoder):
#   "ultrafast", "superfast", "veryfast", "faster", "fast",
#   "medium" (default), "slow", "slower", "veryslow", "placebo"
#   Slower = better compression and quality, but takes longer

# For hevc_vaapi (Linux hardware encoding):
#   "veryfast", "fast", "medium", "slow" (not all drivers support all)

# For hevc_qsv (Intel QuickSync):
#   "veryfast", "faster", "fast", "medium", "slow", "slower"

ENCODE_PRESET="p3"

# Duration in seconds for test encoding (used to estimate file size before full encoding)
# Helps skip files where re-encoding won’t reduce size significantly
# Sample will be taken at 1/4th of the duration
TEST_DURATION=5

#Expected ratio between old and new encoded file to allow transcoding
MIN_SIZE_RATIO=0.8

#Skip files below this bitrate (in kbps)
MIN_BITRATE=2500
MIN_BYTE_PER_SEC=$((MIN_BITRATE * 1000 / 8))


###################
# System settings
##################
offset_auto=0
RECURSIVE=0
raw_min=0
MIN_SIZE_BYTES=0
FOLDER=""
DRY_RUN=0
KEEP_ORIGINAL=0
ALLOW_H265=0
ALLOW_AV1=0
BACKUP_DIR=""
CLEAN_ONLY=0
PURGE_ONLY=0
STOP_AFTER_HOURS=0
REGEX_FILTER=""


# =====================
# Function Definitions
# =====================


print_size() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then
    LC_NUMERIC=C printf "%.2f GB" "$(echo "scale=2; $bytes / 1073741824" | bc -l)"
  else
    LC_NUMERIC=C printf "%.2f MB" "$(echo "scale=2; $bytes / 1048576" | bc -l)"
  fi
}

print_boxed_message() {
    local message="$1"
    local padding=2
    local stripped_message=$(echo "$message" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
    local length=${#stripped_message}
    local width=$((length + padding * 2))
    local top="┌$(printf '─%.0s' $(seq 1 "$width"))┐"
    local bottom="└$(printf '─%.0s' $(seq 1 "$width"))┘"
    local middle="│$(printf ' %.0s' $(seq 1 "$padding"))$message$(printf ' %.0s' $(seq 1 "$padding"))│"
    echo "$top"
    echo "$middle"
    echo "$bottom"
}

build_ffmpeg_command() {
  local input_file="$1"
  local output_file="$2"
  local duration="$3"
  local mode="$4"
  local offset="${5:-0}"  # offset en secondes, par défaut 0
  local cq_value="${6:-$CQ}" # Dynamic CQ, fallback on global $CQ if undefined
  local ffmpeg_opts=()
  local timeout_limit=0
  local stats_opts=()
  if [[ "$mode" != "test" ]]; then
    stats_opts+=("-stats")
  fi

  [[ "$USE_HWACCEL" == "true" ]] && ffmpeg_opts+=("-hwaccel" "$HWACCEL_TYPE")

  if [[ "$mode" == "test" ]]; then
    ffmpeg_opts+=("-ss" "$offset" "-t" "$TEST_DURATION")
    timeout_limit=$((30 * 5))  # 5 minutes
  else
    timeout_limit=$((3 * 3600)) # 3 hours
  fi
  
  # in case of subtitle error
  if [[ "$mode" == "no_sub" ]]; then
    ffmpeg_opts+=("-sn")
  fi

  # Only needed for mp4 and mov to enhance compatibility with Apple products
  container_ext="${input_file##*.}"
  container_args=()
  if [[ "$container_ext" =~ ^(mp4|mov|MP4|MOV)$ ]]; then
    container_args=(-tag:v hvc1 -movflags +faststart)
  fi

  timeout --foreground "$timeout_limit" \
    ffmpeg -y "${ffmpeg_opts[@]}" \
    -i "$input_file" \
    -map 0:v -map 0:a? -map 0:s? -hide_banner -loglevel error "${stats_opts[@]}" \
    -c:v "$VIDEO_CODEC" -preset "$ENCODE_PRESET" -rc vbr -cq "$cq_value" \
    -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" \
    -c:s copy \
    "${container_args[@]}" \
    "$output_file"
}


print_boxed_message_multiline() {
    local padding=2
    local lines=()
    local max_length=0

    # Read multiline input via stdin (so we can preserve ANSI codes correctly)
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Store original and stripped versions
        lines+=("$line")
        local stripped=$(echo -e "$line" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
        (( ${#stripped} > max_length )) && max_length=${#stripped}
    done

    local width=$((max_length + padding * 2))
    local top="┌$(printf '─%.0s' $(seq 1 "$width"))┐"
    local bottom="└$(printf '─%.0s' $(seq 1 "$width"))┘"

    echo "$top"
    for line in "${lines[@]}"; do
        local stripped=$(echo -e "$line" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
        local pad_right=$((width - ${#stripped} - padding))
        printf "│%*s%s%*s│\n" $padding "" "$(echo -e "$line")" $pad_right ""
    done
    echo "$bottom"
}

clear

echo "██   ██ ██████   ██████  ███████     ███████ ███    ██  ██████  ██████  ██████  ███████ ██████  
██   ██      ██ ██       ██          ██      ████   ██ ██      ██    ██ ██   ██ ██      ██   ██ 
███████  █████  ███████  ███████     █████   ██ ██  ██ ██      ██    ██ ██   ██ █████   ██████  
██   ██ ██      ██    ██      ██     ██      ██  ██ ██ ██      ██    ██ ██   ██ ██      ██   ██ 
██   ██ ███████  ██████  ███████     ███████ ██   ████  ██████  ██████  ██████  ███████ ██   ██
"




[[ "$USE_HWACCEL" == "true" ]] && ! ffmpeg -hide_banner -hwaccels 2>/dev/null | grep -q "$HWACCEL_TYPE" && {
  echo "⚠️  Hardware acceleration type '$HWACCEL_TYPE' not supported. Disabling."
  USE_HWACCEL=false
  VIDEO_CODEC="libx265"
}

# =====================
# Argument Parsing
# =====================


while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) RECURSIVE=1 ; shift ;;
    min=*) raw_min="${1#min=}"; MIN_SIZE_BYTES=$(echo "$raw_min" | sed 's/,/./' | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024}') ; shift ;;
    test=*) TEST_DURATION="${1#test=}"; TEST_DURATION=${TEST_DURATION%.*} ; shift ;;
    --dry-run) DRY_RUN=1 ; shift ;;
    --keep-original) KEEP_ORIGINAL=1 ; shift ;;
    --allow-h265) ALLOW_H265=1 ; shift ;;
    --allow-av1) ALLOW_AV1=1 ; shift ;;
    -backup) BACKUP_DIR="$2" ; shift 2 ;;
    --clean) CLEAN_ONLY=1 ; shift ;;
    --purge) PURGE_ONLY=1 ; shift ;;
	--stop-after) STOP_AFTER_HOURS=$(echo "$2" | sed 's/,/./' | awk '{printf "%.0f", $1}'); shift 2 ;;
    --regex=*) REGEX_FILTER="${1#--regex=}" ; shift ;;
    -h) usage ;;
    *) [[ -z "$FOLDER" ]] && FOLDER="$1" || usage; shift ;;
  esac
done

[[ -z "$FOLDER" || ! -d "$FOLDER" ]] && { echo "❌ Folder not found or not specified: $FOLDER"; exit 1; }


# =====================
# Cleaning task
# =====================
if (( CLEAN_ONLY > 0 )); then
  echo "🧹 Cleaning temporary files..."
  find_opts=( "$FOLDER" )
  (( RECURSIVE == 0 )) && find_opts+=( -maxdepth 1 )

  patterns=( -name '.tmp_encode_*' -o -name '.tmp_encode_test_*' )

  find "${find_opts[@]}" -type f \( "${patterns[@]}" \) -print0 |
  while IFS= read -r -d '' file; do
    echo "🗑️  Removing: $file"
    rm -f "$file"
  done

  echo "✅ Cleanup complete."
  exit 0
fi

# =====================
# Purge encoded.list
# =====================
if (( PURGE_ONLY > 0 )); then
  echo "🧹 Purging encoded.list and failed.list files..."
  find_opts=( "$FOLDER" )
  (( RECURSIVE == 0 )) && find_opts+=( -maxdepth 1 )

  patterns=( -name 'encoded.list' )

  find "${find_opts[@]}" -type f \( "${patterns[@]}" \) -print0 |
  while IFS= read -r -d '' file; do
    echo "🗑️  Removing: $file"
    rm -f "$file"
  done

  patterns=( -name 'failed.list' )

  find "${find_opts[@]}" -type f \( "${patterns[@]}" \) -print0 |
  while IFS= read -r -d '' file; do
    echo "🗑️  Removing: $file"
    rm -f "$file"
  done

  echo "✅ Purge complete."
  exit 0
fi

############################
# Startup
############################

print_config() {
  print_boxed_message_multiline <<EOF
\e[1;1mENCODING SETTINGS\e[0m
\e[1;33mHardware Acceleration\e[0m      ${USE_HWACCEL} (${HWACCEL_TYPE})
\e[1;33mVideo Codec\e[0m                ${VIDEO_CODEC}
\e[1;33mAudio Codec\e[0m                ${AUDIO_CODEC} @ ${AUDIO_BITRATE}
\e[1;33mConstant Quality :\e[0m        
\e[1;33m->${CQ_WIDTH_THRESHOLD}\e[0m                     ${CQ_HD}
\e[1;33m-<${CQ_WIDTH_THRESHOLD}\e[0m                     ${CQ_SD}
\e[1;33m-Default\e[0m                   ${CQ}
\e[1;33mEncoding Preset\e[0m            ${ENCODE_PRESET}

\e[1;1mMEDIA FILTERS\e[0m
\e[1;33mMinimum bitrate\e[0m            ${MIN_BITRATE}kbps
\e[1;33mTest Clip Duration\e[0m         (3x) ${TEST_DURATION}s
\e[1;33mMinimum Size Ratio\e[0m         ${MIN_SIZE_RATIO}

\e[1;1mONE-TIME SETTINGS\e[0m  
\e[1;33mFolder\e[0m                     ${FOLDER}
\e[1;33mRecursive\e[0m                  ${RECURSIVE}
\e[1;33mREGEX Filter\e[0m               ${REGEX_FILTER}
\e[1;33mMinimum Size\e[0m               ${raw_min} GB
\e[1;33mKeep original\e[0m              ${KEEP_ORIGINAL}
\e[1;33mStop after\e[0m                 ${STOP_AFTER_HOURS}h
\e[1;33mAllow H265\e[0m                 ${ALLOW_H265}
\e[1;33mAllow AV1\e[0m                  ${ALLOW_AV1}
\e[1;33mBackup directory\e[0m           ${BACKUP_DIR}
\e[1;33mDry run\e[0m                    ${DRY_RUN}
EOF
 echo""
}

print_config

find_cmd=(find "$FOLDER")
[[ $RECURSIVE -eq 0 ]] && find_cmd+=( -maxdepth 1 )
find_cmd+=( -type f \( -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.wmv' -o -iname '*.flv' \) )

echo "Scanning..."
candidates=()
all_videos=0
already_encoded=0
already_failed=0


# =====================
# Scanning and filtering
# =====================

while IFS= read -r f; do
  base=$(basename "$f")
  dir=$(dirname "$f")
  list_file="$dir/encoded.list"
  failed_file="$dir/failed.list"


   all_videos=$((all_videos + 1))
  echo -ne "\r├── $all_videos video files found / ${#candidates[@]} will be encoded / $already_encoded indicated as encoded / $already_failed indicated as failed"

  # Apply regex filter if specified
  if [[ -n "$REGEX_FILTER" && ! "$f" =~ $REGEX_FILTER ]]; then
    continue
  fi

  #detect files too small
  size_bytes=$(stat -c%s "$f" 2>/dev/null) || continue
  (( MIN_SIZE_BYTES > 0 && size_bytes < MIN_SIZE_BYTES )) && continue
  
  #detect already encoded
  if [[ -f "$list_file" ]] && grep -Fxq "$base" "$list_file"; then
  already_encoded=$((already_encoded + 1))
  continue
  fi
  
  #detect already failed
  if [[ -f "$failed_file" ]] && grep -Fxq "$base" "$failed_file"; then
    already_failed=$((already_failed + 1))
    continue
  fi

  #detect codec
  codec_name=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || continue
  [[ "$codec_name" == "hevc" && $ALLOW_H265 -eq 0 ]] && continue
  [[ "$codec_name" == "av1" && $ALLOW_AV1 -eq 0 ]] && continue

  #detect duration
  duration=$(ffprobe -v quiet -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$f")
  duration_int=${duration%.*}
  [[ -z "$duration_int" || "$duration_int" -le 0 ]] && continue
  
  candidates+=("$f")



  
done < <( "${find_cmd[@]}" )

  echo -ne "\r├── $all_videos video files found / ${#candidates[@]} will be encoded / $already_encoded indicated as encoded / $already_failed indicated as failed"
  echo ""

if (( DRY_RUN == 1 )); then
  echo -e "\n📝 Compatible files for encoding:"
  for file in "${candidates[@]}"; do
    size_bytes=$(stat -c%s "$file")
    size_fmt=$(print_size "$size_bytes")
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$file")
    duration=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$file")
    duration_fmt=$(printf "%.0f sec" "$duration")
    echo "  📆 $(basename "$file") | $size_fmt | $codec | $duration_fmt"
  done
  echo -e "\n✅ ${#candidates[@]} file(s) listed."
  exit 0
fi



# =====================
# Encoding tasks
# =====================

encoding_number=0
start_time=$(date +%s)
stop_after_seconds=$(awk "BEGIN {printf \"%.0f\", $STOP_AFTER_HOURS * 3600}")

for f in "${candidates[@]}"; do
  encoding_number=$((encoding_number + 1))
  base=$(basename "$f")
  dir=$(dirname "$f")
  list_file="$dir/encoded.list"
  failed_file="$dir/failed.list"
  size_bytes=$(stat -c%s "$f")
  duration=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$f")
  duration_int=${duration%.*}
  duration_view=$(printf '%02d:%02d:%02d' $((duration_int/3600)) $(( (duration_int%3600)/60 )) $((duration_int%60)))
  height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$f" 2>/dev/null)
  
  # Try to get the video width using ffprobe
  width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$f" 2>/dev/null)

  # Fallback if ffprobe fails or returns an invalid width
  if [[ $? -ne 0 || -z "$width" || "$width" -le 0 ]]; then
    echo "Warning: Unable to determine width for '$f', using fallback CQ=$CQ"
    file_CQ="$CQ"
  else
    # Assign CQ based on width threshold
    if (( width >= $CQ_WIDTH_THRESHOLD )); then
      file_CQ="$CQ_HD"
    else
      file_CQ="$CQ_SD"
    fi
  fi
  

  if (( STOP_AFTER_HOURS > 0 )); then
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))
    if (( elapsed >= stop_after_seconds )); then
      echo ""
      echo "⏱️  Stop limit of $STOP_AFTER_HOURS hour(s) reached. Exiting."
      break
    fi
  fi


  echo ""
  print_boxed_message "Task $encoding_number / ${#candidates[@]} : $(basename "$f") ($(print_size "$size_bytes") | $duration_view | "$width"x"$height" | CQ=$file_CQ)"

  ext="${base##*.}"
  ext_lower=$(echo "$ext" | tr 'A-Z' 'a-z')
  output_ext="$ext_lower"
  [[ "$ext_lower" == "avi" || "$ext_lower" == "mp4" ]] && output_ext="mkv"
  tmp_file="$dir/.tmp_encode_${base%.*}.$output_ext"
  tmp_test="$dir/.tmp_encode_test_${base}"
  
  
##############################
# EXCLUDING SMALL FILES
###############################
  
  if (( size_bytes / duration_int < MIN_BYTE_PER_SEC )); then
  echo "🔎 So small, no sample needed !"
  echo "$base" >> "$list_file"
  echo "✅ Marked as encoded "

  continue
  fi

##############################
# SAMPLING
###############################


  # Perform 3 test encodings at 1/4, 1/2, and 3/4 of the duration
    offsets=(
      $(( duration_int / 4 ))
      $(( duration_int / 2 ))
      $(( duration_int * 3 / 4 ))
    )

total_test_size=0
success=true
test_number=0

print_timeline() {
  local step=$1
  case $step in
    1) echo "|---🔎---|----|----| @ $(( duration_int / 4 ))s" ;;
    2) echo "|----|---🔎---|----| @ $(( duration_int / 2 ))s";;
    3) echo "|----|----|---🔎---| @ $(( duration_int * 3 / 4 ))s" ;;
    *) echo "|----|----|----|----|" ;;  #fallback
  esac
}

echo "🔎 Encoding samples (3x ${TEST_DURATION}s)"
test_sizes=()
for offset_auto in "${offsets[@]}"; do
  test_number=$((test_number + 1))

  # Affichage graphique ASCII de la timeline avec curseur
  print_timeline $test_number

  if ! build_ffmpeg_command "$f" "$tmp_test" "$duration" test "$offset_auto" "$file_CQ" < /dev/null ; then
    echo "├── ❌ Test encoding failed at offset ${offset_auto}s"
    rm -f "$tmp_test"
    success=false
    break
  fi

  test_size=$(stat -c%s "$tmp_test")
  test_sizes+=("$test_size")
  rm -f "$tmp_test"
done

# If any test failed, skip the file and mark it as failed
if ! $success; then
  echo "$base" >> "$failed_file"
  continue
fi

# 🔸 Calcul de la médiane
IFS=$'\n' sorted_sizes=($(sort -n <<<"${test_sizes[*]}"))
unset IFS
median_test_size=${sorted_sizes[1]}  # 2e élément de la liste triée (index 1)

# 🔸 Estimation avec la médiane
estimated_size=$(( median_test_size * duration_int / TEST_DURATION ))
echo "├── Estimated size (median of 3 samples): $(print_size "$estimated_size")"

threshold_bytes=$(awk "BEGIN {printf \"%d\", $MIN_SIZE_RATIO * $size_bytes}")

if (( estimated_size >= threshold_bytes )); then
  perc=$(awk "BEGIN {printf \"%.0f\", $MIN_SIZE_RATIO * 100}")
  echo "├── ❌ Estimated size > ${perc}% of original, skipping"
  echo "$base" >> "$list_file"
  continue
fi

##############################
# FULL ENCODING
###############################


echo "▶️  Full encoding ($duration_view)"
  
output=$(build_ffmpeg_command "$f" "$tmp_file" "$duration" "$file_CQ" < /dev/null 2>&1 | tee >(cat >&2))
ffmpeg_status=$?

# Case 1: Subtitle codec issue — retry without subtitles
if echo "$output" | grep -qE 'Subtitle codec|Could not write header'; then
  echo "├── ⚠️ Subtitle codec error detected, retrying without subtitles..."
  output=$(build_ffmpeg_command "$f" "$tmp_file" "$duration" "$cq" no_sub < /dev/null 2>&1 | tee >(cat >&2))
  if [ $? -eq 0 ]; then
    echo "├── ✅ Encoding succeeded without subtitles"
  else
    echo "├── ❌ Encoding failed even without subtitles"
    echo "$output"
    rm -f "$tmp_file"
    echo "$base" >> "$failed_file"
    continue
  fi

# Case 2: General failure or critical errors
elif [[ $ffmpeg_status -ne 0 ]] || echo "$output" | grep -qE 'Could not write header|Error initializing output stream|invalid encoder|Invalid argument|Conversion failed|non-monotonically increasing'; then
  echo "├── ❌ Full encoding failed"
  echo "$output"
  rm -f "$tmp_file"
  echo "$base" >> "$failed_file"
  continue

# Case 3: Success (no error detected and ffmpeg exited cleanly)
else
  echo "├── ✅ Encoding succeeded"
fi


# Compare durations
echo "⏳  Duration validation"

new_duration=""
ffprobe_output=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$tmp_file" 2>&1)
ffprobe_status=$?

if (( ffprobe_status == 0 )) && [[ "$ffprobe_output" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  new_duration="${ffprobe_output}"
else
  echo "├── ⚠️ ffprobe failed or invalid duration: $ffprobe_output"
  echo "├── ⚠️ Duration could not be validated, failing this file"
  rm -f "$tmp_file" || true
  echo "$base" >> "$failed_file"
  continue
fi

new_duration_int=${new_duration%.*}
duration_diff=$(( duration_int - new_duration_int ))
if (( duration_diff < 0 )); then
  duration_diff=$(( -duration_diff ))
fi

max_diff=2
if (( duration_diff > max_diff )); then
  echo "├── ❌ Duration mismatch (diff: ${duration_diff}s), encoded file rejected"
  rm -f "$tmp_file" || true
  echo "$base" >> "$failed_file"
  continue
else
  echo "├── ✅ Duration validated (diff: ${duration_diff}s)"
fi

echo "🎥  Video file replacement"

  new_size=$(stat -c%s "$tmp_file")
  if (( new_size < size_bytes )); then
    if (( KEEP_ORIGINAL == 1 )); then
      mv -f "$tmp_file" "${f%.*}_encoded.$output_ext"
      echo "├── ✅ Saved as ${f%.*}_encoded.$output_ext"
    else
      if [[ -n "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -f "$f" "$BACKUP_DIR/"
        echo "├── ☁️  Backed up original to $BACKUP_DIR"
      fi
      mv -f "$tmp_file" "$f"
      echo "├── Replaced original"
    fi
    orig_size_fmt=$(print_size "$size_bytes")
    new_size_fmt=$(print_size "$new_size")
    reduc_percent=$(( (size_bytes - new_size)*100 / size_bytes ))
    echo "├── Size reduced: $orig_size_fmt → $new_size_fmt | −${reduc_percent}%"
  else
    echo "├── ⚠️  Encoded file is larger, skipping replacement"
    rm -f "$tmp_file"
  fi
  echo "$base" >> "$list_file"
done
