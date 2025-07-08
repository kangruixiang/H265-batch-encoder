#!/bin/bash

# =======================
# Video Encoding Script
# =======================
# Supported formats: .mkv .avi .mp4 .mov .wmv .flv
# This script re-encodes video files using hardware-accelerated HEVC (H.265) compression,
# optionally skipping already optimized files and ignoring small files.
#
# Usage:
#   ./script.sh [-R] [min=X] <folder>
#     -R      : Encode recursively inside subfolders
#     min=X   : Ignore files smaller than X GB
#     -h      : Show this help message

set -e

# ===========================
# User Configuration Section
# ===========================
# These variables allow you to customize encoding behavior without modifying the logic below.

# Use hardware acceleration (true/false)
USE_HWACCEL=true

# Type of hardware acceleration: "cuda", "vaapi", "qsv", etc.
HWACCEL_TYPE="cuda"

# Video codec to use: "hevc_nvenc" (for CUDA), "libx265" (CPU), etc.
VIDEO_CODEC="hevc_nvenc"

# Audio codec and bitrate
AUDIO_CODEC="aac"
AUDIO_BITRATE="256k"

# Constant quality factor (lower = better quality, larger file; range 0–51)
CQ="30"

# Encoding preset (speed vs. quality trade-off)
ENCODE_PRESET="p3"

# =====================
# Function Definitions
# =====================

# Display help message
usage() {
  echo "Usage: $0 [-R] [min=X] <folder>"
  echo "  -R      : Encode recursively"
  echo "  min=X   : Skip files smaller than X GB"
  echo "  -h      : Show this help message"
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
    ffmpeg_opts+=("-ss" "0" "-t" "2")
  fi

  ffmpeg -y "${ffmpeg_opts[@]}" \
    -i "$input_file" \
    -map 0:v -map 0:a? -map 0:s? \
    -c:v "$VIDEO_CODEC" -preset "$ENCODE_PRESET" -rc vbr -cq "$CQ" \
    -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" \
    -c:s copy \
    "$output_file"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) RECURSIVE=1; shift ;;
    min=*) MIN_SIZE="${1#min=}"; shift ;;
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
# Main Processing Loop
# =====================

while IFS= read -r f; do
  dir=$(dirname "$f")
  base=$(basename "$f")
  list_file="$dir/encoded.list"

  size_bytes=$(stat -c%s "$f")
  size_gb=$(( size_bytes / 1024 / 1024 / 1024 ))

  # Skip small files without recording
  if (( MIN_SIZE > 0 && size_gb < MIN_SIZE )); then
    echo "⚠️  File too small (<${MIN_SIZE}GB), skipping: $base"
    continue
  fi

  # Skip if already encoded
  if [[ -f "$list_file" ]] && grep -Fxq "$base" "$list_file"; then
    echo "✅ Already encoded: $base"
    continue
  fi

  # Skip if already in HEVC or AV1
  codec_name=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$f")
  if [[ "$codec_name" == "hevc" || "$codec_name" == "av1" ]]; then
    echo "⚠️  Already in $codec_name, skipping: $base"
    echo "$base" >> "$list_file"
    continue
  fi

  # Get video duration in seconds
  duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f")
  duration=${duration%.*}
  if [[ -z "$duration" || "$duration" -le 0 ]]; then
    echo "❌ Duration undetected or zero, skipping: $base"
    echo "$base" >> "$list_file"
    continue
  fi

  # Prepare temp output filenames
  tmp_test="$dir/.tmp_encode_test_${base}"
  ext="${base##*.}"
  ext_lower=$(echo "$ext" | tr 'A-Z' 'a-z')
  output_ext="$ext_lower"
  [[ "$ext_lower" == "avi" || "$ext_lower" == "mp4" ]] && output_ext="mkv"
  tmp_file="$dir/.tmp_encode_${base%.*}.$output_ext"

  echo "🔎 Encoding test (2s): $base"
  if ! build_ffmpeg_command "$f" "$tmp_test" "$duration" test < /dev/null &> /dev/null; then
    echo "❌ Test encoding failed"
    rm -f "$tmp_test"
    continue
  fi

  test_size=$(stat -c%s "$tmp_test")
  estimated_size=$(( test_size * duration / 2 ))
  rm -f "$tmp_test"

  # Skip if estimated output is > 70% of original size
  if (( estimated_size >= size_bytes * 7 / 10 )); then
    echo "❌ Estimated size > 70% of original, skipping: $base"
    echo "$base" >> "$list_file"
    continue
  fi

  echo "▶️  Full encoding: $base"
  if ! build_ffmpeg_command "$f" "$tmp_file" "$duration" full < /dev/null; then
    echo "❌ Full encoding failed: $base"
    rm -f "$tmp_file"
    continue
  fi

  new_size=$(stat -c%s "$tmp_file")
  if (( new_size < size_bytes )); then
    if [[ "$output_ext" != "$ext_lower" ]]; then
      new_file="${f%.*}.$output_ext"
      mv -f "$tmp_file" "$new_file"
      rm -f "$f"
      echo "✅ Replaced with new file: $new_file"
    else
      mv -f "$tmp_file" "$f"
      echo "✅ Replaced original: $base"
    fi

    orig_size_fmt=$(print_size "$size_bytes")
    new_size_fmt=$(print_size "$new_size")
    reduc_percent=$(( (size_bytes - new_size)*100 / size_bytes ))
    echo "✅ Size reduced: original = $orig_size_fmt | new = $new_size_fmt | reduction = ${reduc_percent}%"
  else
    echo "⚠️  Encoded file is larger, keeping original: $base"
    rm -f "$tmp_file"
  fi

  echo "$base" >> "$list_file"
done < <("${find_cmd[@]}")
