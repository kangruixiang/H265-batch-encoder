#!/bin/bash

# =======================
# Video Encoding Script
# =======================
# Supported formats: .mkv .avi .mp4 .mov .wmv .flv
# This script re-encodes video files using hardware-accelerated HEVC (H.265) compression,
# optionally skipping already optimized files and ignoring small files.
#
# Usage:
#   ./script.sh [-R] [min=X] [test=Y] [--dry-run] [--keep-original] [--allow-h265] [--allow-av1] [-backup /path] <folder>
#     -R              : Encode recursively inside subfolders
#     min=X.YZ        : Ignore files smaller than X.YZ GB
#     test=N          : Use N seconds for the test encode (default: 5)
#     --dry-run       : Only show compatible files without encoding
#     --keep-original : Keep original files instead of replacing them
#     --allow-h265    : Allow files already encoded in H.265
#     --allow-av1     : Allow files already encoded in AV1
#     -backup /path   : Save original files to backup path (used only if not using --keep-original)
#     -h              : Show this help message

set -e

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
CQ="30"

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
TEST_DURATION=5

# =====================
# Function Definitions
# =====================
usage() {
  grep '^#' "$0" | cut -c 4-
  exit 0
}

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
  local ffmpeg_opts=()
  [[ "$USE_HWACCEL" == "true" ]] && ffmpeg_opts+=("-hwaccel" "$HWACCEL_TYPE")
  [[ "$mode" == "test" ]] && ffmpeg_opts+=("-ss" "0" "-t" "$TEST_DURATION")

  ffmpeg -y "${ffmpeg_opts[@]}" \
    -i "$input_file" \
    -map 0:v -map 0:a? -map 0:s? -hide_banner -loglevel error -stats \
    -c:v "$VIDEO_CODEC" -preset "$ENCODE_PRESET" -rc vbr -cq "$CQ" \
    -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" \
    -c:s copy \
    "$output_file"
}

[[ "$USE_HWACCEL" == "true" ]] && ! ffmpeg -hide_banner -hwaccels 2>/dev/null | grep -q "$HWACCEL_TYPE" && {
  echo "⚠️  Hardware acceleration type '$HWACCEL_TYPE' not supported. Disabling."
  USE_HWACCEL=false
  VIDEO_CODEC="libx265"
}

# =====================
# Argument Parsing
# =====================
RECURSIVE=0
MIN_SIZE_BYTES=0
FOLDER=""
DRY_RUN=0
KEEP_ORIGINAL=0
ALLOW_H265=0
ALLOW_AV1=0
BACKUP_DIR=""

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
    -h) usage ;;
    *) [[ -z "$FOLDER" ]] && FOLDER="$1" || usage; shift ;;
  esac
done

[[ -z "$FOLDER" || ! -d "$FOLDER" ]] && { echo "❌ Folder not found or not specified: $FOLDER"; exit 1; }

find_cmd=(find "$FOLDER")
[[ $RECURSIVE -eq 0 ]] && find_cmd+=( -maxdepth 1 )
find_cmd+=( -type f \( -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.wmv' -o -iname '*.flv' \) )

echo "Scanning..."
candidates=()
all_videos=0

# =====================
# Scanning and filtering
# =====================

while IFS= read -r f; do
  base=$(basename "$f")
  dir=$(dirname "$f")
  list_file="$dir/encoded.list"

   all_videos=$((all_videos + 1))
	echo -ne "\r├── $all_videos video files found / ${#candidates[@]} will be encoded"

  size_bytes=$(stat -c%s "$f" 2>/dev/null) || continue
  (( MIN_SIZE_BYTES > 0 && size_bytes < MIN_SIZE_BYTES )) && continue

  [[ -f "$list_file" ]] && grep -Fxq "$base" "$list_file" && continue

  codec_name=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || continue
  [[ "$codec_name" == "hevc" && $ALLOW_H265 -eq 0 ]] && continue
  [[ "$codec_name" == "av1" && $ALLOW_AV1 -eq 0 ]] && continue

  duration=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$f")
  duration_int=${duration%.*}
  [[ -z "$duration_int" || "$duration_int" -le 0 ]] && continue

  candidates+=("$f")


  
done < <( "${find_cmd[@]}" )

  echo -ne "\r├── $all_videos video files found / ${#candidates[@]} will be encoded"
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

for f in "${candidates[@]}"; do
  encoding_number=$((encoding_number + 1))
  base=$(basename "$f")
  dir=$(dirname "$f")
  list_file="$dir/encoded.list"
  size_bytes=$(stat -c%s "$f")
  duration=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$f")
  duration_int=${duration%.*}
  duration_view=$(printf '%02d:%02d:%02d' $((duration_int/3600)) $(( (duration_int%3600)/60 )) $((duration_int%60)))
  echo ""
  print_boxed_message "Task $encoding_number / ${#candidates[@]} : $(basename "$f") ($(print_size "$size_bytes") | $duration_view)"

  ext="${base##*.}"
  ext_lower=$(echo "$ext" | tr 'A-Z' 'a-z')
  output_ext="$ext_lower"
  [[ "$ext_lower" == "avi" || "$ext_lower" == "mp4" ]] && output_ext="mkv"
  tmp_file="$dir/.tmp_encode_${base%.*}.$output_ext"
  tmp_test="$dir/.tmp_encode_test_${base}"

  echo "🔎 Encoding sample (${TEST_DURATION}s)"
  build_ffmpeg_command "$f" "$tmp_test" "$duration" test < /dev/null &> /dev/null || {
    echo "├── ❌ Test encoding failed"
    rm -f "$tmp_test"
    continue
  }

  test_size=$(stat -c%s "$tmp_test")
  estimated_size=$(( test_size * duration_int / TEST_DURATION ))
  echo "├── Estimated size: $(print_size "$estimated_size")"
  rm -f "$tmp_test"

  (( estimated_size >= size_bytes * 7 / 10 )) && {
    echo "├── ❌ Estimated size > 70% of original, skipping"
    echo "$base" >> "$list_file"
    continue
  }

  echo "▶️  Full encoding ($duration_view)"
  build_ffmpeg_command "$f" "$tmp_file" "$duration" full < /dev/null || {
    echo "├── ❌ Full encoding failed"
    rm -f "$tmp_file"
    continue
  }

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
      echo "├── ✅ Replaced original"
    fi
    orig_size_fmt=$(print_size "$size_bytes")
    new_size_fmt=$(print_size "$new_size")
    reduc_percent=$(( (size_bytes - new_size)*100 / size_bytes ))
    echo "├── ✅ Size reduced: $orig_size_fmt → $new_size_fmt | −${reduc_percent}%"
  else
    echo "├── ⚠️  Encoded file is larger, skipping replacement"
    rm -f "$tmp_file"
  fi
  echo "$base" >> "$list_file"
  echo "--------------------END------------------------"
done
