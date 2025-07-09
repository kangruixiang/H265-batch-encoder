#!/bin/bash

# =======================
# Video Encoding Script
# =======================
# Supported formats: .mkv .avi .mp4 .mov .wmv .flv
# This script re-encodes video files using hardware-accelerated HEVC (H.265) compression,
# optionally skipping already optimized files and ignoring small files.
#
# Usage:
#   ./script.sh [-R] [min=X] [test=Y] [--dry-run] <folder>
#     -R          : Encode recursively inside subfolders
#     min=X.YZ       : Ignore files smaller than X.YZ GB
#     test=Y      : Use Y seconds for the test encode (default: 5)
#     --dry-run   : Only show compatible files without encoding
#     -h          : Show this help message

set -e

# ===========================
# User Configuration Section
# ===========================
# These variables allow you to customize encoding behavior without modifying the logic below.

# Use hardware acceleration (true/false)
USE_HWACCEL=true

# Type of hardware acceleration: "cuda", "vaapi", "qsv", etc.
HWACCEL_TYPE="cuda"

# Video codec to use:
# - "hevc_nvenc" for NVIDIA CUDA
# - "libx265" for CPU encoding
VIDEO_CODEC="hevc_nvenc"

# Audio codec and bitrate
AUDIO_CODEC="aac"
AUDIO_BITRATE="256k"

# Constant quality factor for video (0–51):
# - Lower = better quality and larger file
# - Higher = lower quality and smaller file
CQ="30"

# Encoding preset (speed vs. quality trade-off)
# -------------------------------------------------------
# This option controls the speed/efficiency of the encoder.
# Available presets depend on the encoder used (e.g., hevc_nvenc).
# 
# For NVIDIA NVENC:
#   - p1: slowest, highest quality
#   - p2
#   - p3: balanced quality/speed (default)
#   - p4
#   - p5
#   - p6
#   - p7: fastest, lowest compression
#
# Note: Lower numbers = slower but better quality
ENCODE_PRESET="p3"

# Duration of the test encode in seconds
TEST_DURATION=5

# =====================
# Function Definitions
# =====================

# Display help message
usage() {
  echo "Usage: $0 [-R] [min=X] [test=Y] [--dry-run] <folder>"
  echo "  -R          : Encode recursively"
  echo "  min=X       : Skip files smaller than X GB"
  echo "  test=Y      : Use Y seconds for test encode (default: $TEST_DURATION)"
  echo "  --dry-run   : Only show compatible files without encoding"
  echo "  -h          : Show this help message"
  exit 0
}

# Print human-readable file size
print_size() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then
    LC_NUMERIC=C printf "%.2f GB" "$(echo "scale=2; $bytes / 1073741824" | bc -l)"
  else
    LC_NUMERIC=C printf "%.2f MB" "$(echo "scale=2; $bytes / 1048576" | bc -l)"
  fi
}

# Build ffmpeg command with given parameters
build_ffmpeg_command() {
  local input_file="$1"
  local output_file="$2"
  local duration="$3"
  local mode="$4"  # "test" or "full"

  local ffmpeg_opts=()

  if [[ "$USE_HWACCEL" == "true" ]]; then
    ffmpeg_opts+=("-hwaccel" "$HWACCEL_TYPE")
  fi

  if [[ "$mode" == "test" ]]; then
    ffmpeg_opts+=("-ss" "0" "-t" "$TEST_DURATION")
  fi

  ffmpeg -y "${ffmpeg_opts[@]}" \
    -i "$input_file" \
    -map 0:v -map 0:a? -map 0:s? -hide_banner -loglevel error -stats \
    -c:v "$VIDEO_CODEC" -preset "$ENCODE_PRESET" -rc vbr -cq "$CQ" \
    -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" \
    -c:s copy \
    "$output_file"
}

#Display nice frame when starting process
print_boxed_message() {
    local message="$1"
    local padding=2
    local length=${#message}
    local width=$((length + padding * 2))
    local top="┌$(printf '─%.0s' $(seq 1 "$width"))┐"
    local bottom="└$(printf '─%.0s' $(seq 1 "$width"))┘"
    local middle="│$(printf ' %.0s' $(seq 1 "$padding"))$message$(printf ' %.0s' $(seq 1 "$padding"))│"

    echo "$top"
    echo "$middle"
    echo "$bottom"
}


# Check if hwaccel codec is available
if [[ "$USE_HWACCEL" == "true" ]]; then
  if ! ffmpeg -hide_banner -hwaccels 2>/dev/null | grep -q "$HWACCEL_TYPE"; then
    echo "⚠️  Hardware acceleration type '$HWACCEL_TYPE' not supported. Disabling hardware acceleration."
    USE_HWACCEL=false
    VIDEO_CODEC="libx265"
  fi
fi

# =====================
# Argument Parsing
# =====================

RECURSIVE=0
MIN_SIZE=0
FOLDER=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) RECURSIVE=1; shift ;;
    
    min=*)
 	 raw_min="${1#min=}"
 	 MIN_SIZE_BYTES=$(echo "$raw_min" | sed 's/,/./' | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024}')
  	shift
 	 ;;

    
    test=*) TEST_DURATION="${1#test=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h) usage ;;
    *)
      if [[ -z "$FOLDER" ]]; then
        FOLDER="$1"; shift
      else
        usage
      fi
      ;;
  esac
done

if [[ -z "$FOLDER" || ! -d "$FOLDER" ]]; then
  echo "❌ Folder not found or not specified: $FOLDER"
  exit 1
fi

# =====================
# File Discovery
# =====================

# Construct find command
find_cmd=(find "$FOLDER")
[[ $RECURSIVE -eq 0 ]] && find_cmd+=( -maxdepth 1 )
find_cmd+=( -type f \( -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.wmv' -o -iname '*.flv' \) )

# =====================
# Candidate Filtering
# =====================
echo "Scanning..."
all_videos=0
too_small=0
already_h265_or_av1=0
already_encoded=0
corrupted_files=0

candidates=()

while IFS= read -r f; do
  dir=$(dirname "$f")
  base=$(basename "$f")
  list_file="$dir/encoded.list"
  
  all_videos=$((all_videos + 1))
	echo -ne "\r├── $all_videos video files found / ${#candidates[@]} will be encoded"

  if ! size_bytes=$(stat -c%s "$f" 2>/dev/null); then
    corrupted_files=$((corrupted_files + 1))
    continue
  fi

  (( MIN_SIZE_BYTES > 0 && size_bytes < MIN_SIZE_BYTES )) && continue
  if [[ -f "$list_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == "$base" ]] && {
        already_encoded=$((already_encoded + 1))
        continue 2
      }
    done < "$list_file"
  fi

  codec_name=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null) || {
    corrupted_files=$((corrupted_files + 1))
    continue
  }
  [[ -z "$codec_name" ]] && continue
  [[ "$codec_name" == "hevc" || "$codec_name" == "av1" ]] && continue

  duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null) || {
    corrupted_files=$((corrupted_files + 1))
    continue
  }
  duration=${duration%.*}
  [[ -z "$duration" || "$duration" -le 0 ]] && continue

  candidates+=("$f")

done < <("${find_cmd[@]}")

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
    echo "  📦 $(basename "$file") | $size_fmt | $codec | $duration_fmt"
  done
  echo -e "\n✅ ${#candidates[@]} file(s) listed."
  exit 0
fi

# =====================
# Main Processing Loop
# =====================

encoding_number=0

for f in "${candidates[@]}"; do
  dir=$(dirname "$f")
  base=$(basename "$f")
  list_file="$dir/encoded.list"
  encoding_number=$((encoding_number + 1))
  size_bytes=$(stat -c%s "$f")
  duration=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$f")
  duration_int=${duration%.*}
  duration_view=$(printf '%02d:%02d:%02d' $((duration_int/3600)) $(( (duration_int%3600)/60 )) $((duration_int%60)))
  duration=${duration%.*}
  echo ""
  msg="Encoding $encoding_number / ${#candidates[@]} : $base ($(print_size "$size_bytes") | $duration_view)"
  print_boxed_message "$msg"


  tmp_test="$dir/.tmp_encode_test_${base}"
  ext="${base##*.}"
  ext_lower=$(echo "$ext" | tr 'A-Z' 'a-z')
  output_ext="$ext_lower"
  [[ "$ext_lower" == "avi" || "$ext_lower" == "mp4" ]] && output_ext="mkv"
  tmp_file="$dir/.tmp_encode_${base%.*}.$output_ext"

  echo "🔎 Encoding sample (${TEST_DURATION}s)"
  if ! build_ffmpeg_command "$f" "$tmp_test" "$duration" test < /dev/null &> /dev/null; then
    echo "├── ❌ Test encoding failed"
    rm -f "$tmp_test"
    continue
  fi

  test_size=$(stat -c%s "$tmp_test")
  estimated_size=$(( test_size * duration / TEST_DURATION ))
  echo "├── Estimated size: $(print_size "$estimated_size")"
  rm -f "$tmp_test"

  if (( estimated_size >= size_bytes * 7 / 10 )); then
    echo "├── ❌ Estimated size > 70% of original, skipping"
    echo "$base" >> "$list_file"
    continue
  fi

  echo "▶️  Full encoding ($duration_view)"
  if ! build_ffmpeg_command "$f" "$tmp_file" "$duration" full < /dev/null; then
    echo "├── ❌ Full encoding failed"
    rm -f "$tmp_file"
    continue
  fi

  new_size=$(stat -c%s "$tmp_file")
  if (( new_size < size_bytes )); then
    if [[ "$output_ext" != "$ext_lower" ]]; then
      new_file="${f%.*}.$output_ext"
      mv -f "$tmp_file" "$new_file"
      rm -f "$f"
      echo "├── ✅ Replaced with new file: $new_file"
    else
      mv -f "$tmp_file" "$f"
      echo "├── ✅ Replaced original"
    fi

    orig_size_fmt=$(print_size "$size_bytes")
    new_size_fmt=$(print_size "$new_size")
    reduc_percent=$(( (size_bytes - new_size)*100 / size_bytes ))
    echo "├── ✅ Size reduced: original = $orig_size_fmt | new = $new_size_fmt | reduction = ${reduc_percent}%"
  else
    echo "├── ⚠️  Encoded file is larger, keeping original"
    rm -f "$tmp_file"
  fi

  echo "$base" >> "$list_file"
  echo "--------------------END------------------------"
done
