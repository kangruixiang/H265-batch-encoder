#!/bin/bash
# Supported file formats: *.mkv *.avi *.mp4 *.mov *.wmv *.flv

set -e  # Exit immediately if any command fails

# Function: display usage/help
usage() {
  echo "Usage: $0 [-R] [min=X] <folder>"
  echo ""
  echo "Options:"
  echo "  -R         : Recursively scan subfolders"
  echo "  min=X      : Ignore files smaller than X GB (not added to encoded.list)"
  echo "  -h         : Show this help message"
  exit 1
}

# Function: pretty print file sizes
print_size() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then
    LC_NUMERIC=C printf "%.2f GB" "$(echo "scale=2; $bytes / 1073741824" | bc -l)"
  else
    LC_NUMERIC=C printf "%.2f MB" "$(echo "scale=2; $bytes / 1048576" | bc -l)"
  fi
}

# Default values
RECURSIVE=0
MIN_SIZE=0
FOLDER=""

# Argument parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h) usage ;;
    -R) RECURSIVE=1; shift ;;
    min=*) MIN_SIZE="${1#min=}"; shift ;;
    *)
      if [[ -z "$FOLDER" ]]; then
        FOLDER="$1"
        shift
      else
        usage
      fi
      ;;
  esac
done

# Check folder validity
if [[ -z "$FOLDER" ]]; then
  usage
fi

if [[ ! -d "$FOLDER" ]]; then
  echo "❌ Folder not found: $FOLDER"
  exit 1
fi

# Build the find command depending on recursion
find_cmd=(find "$FOLDER")
if [[ $RECURSIVE -eq 0 ]]; then
  find_cmd+=(-maxdepth 1)
fi
find_cmd+=(-type f \( -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.wmv' -o -iname '*.flv' \))

# Main loop over files
while IFS= read -r f; do
  dir=$(dirname "$f")
  base=$(basename "$f")
  list_file="$dir/encoded.list"

  size_bytes=$(stat -c%s "$f")
  size_gb=$(( size_bytes / 1024 / 1024 / 1024 ))

  # Skip small files
  if (( MIN_SIZE > 0 && size_gb < MIN_SIZE )); then
    echo "⚠️ Skipped (smaller than ${MIN_SIZE}GB): $base"
    continue
  fi

  # Skip already encoded files
  if [[ -f "$list_file" ]] && grep -Fxq "$base" "$list_file"; then
    echo "✅ Already encoded: $base"
    continue
  fi

  # Check if video is already in HEVC or AV1
  codec_name=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$f")
  if [[ "$codec_name" == "hevc" || "$codec_name" == "av1" ]]; then
    echo "⚠️ Already in $codec_name format, skipping: $base"
    echo "$base" >> "$list_file"
    continue
  fi

  # Get video duration (in seconds)
  duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f")
  duration=${duration%.*}
  if [[ -z "$duration" || "$duration" -le 0 ]]; then
    echo "❌ Invalid or zero duration, skipping: $base"
    echo "$base" >> "$list_file"
    continue
  fi

  # Define temporary files
  tmp_test="$dir/.tmp_encode_test_${base}"
  ext="${base##*.}"
  ext_lower=$(echo "$ext" | tr 'A-Z' 'a-z')

  # Keep original extension unless it's not ideal
  output_ext="$ext_lower"
  if [[ "$ext_lower" == "avi" || "$ext_lower" == "mp4" ]]; then
    output_ext="mkv"
  fi
  tmp_file="$dir/.tmp_encode_${base%.*}.$output_ext"

  # Test encode a 10s sample
  echo "🔎 Test encoding 10s sample: $base"
  if ! ffmpeg -y -ss 0 -t 10 -hwaccel cuda -i "$f" -map 0 -c:v hevc_nvenc -preset p3 -rc vbr -cq 30 -c:a aac -b:a 256k -c:s copy "$tmp_test" < /dev/null &> /dev/null; then
    echo "❌ Test encoding failed, skipping: $base"
    echo "$base" >> "$list_file"
    rm -f "$tmp_test"
    continue
  fi

  test_size=$(stat -c%s "$tmp_test")
  estimated_size=$(( test_size * duration / 10 ))
  rm -f "$tmp_test"

  # Skip if estimated size > 80% of original
  if (( estimated_size >= size_bytes * 8 / 10 )); then
    echo "❌ Estimated size > 80% of original, skipping: $base"
    echo "$base" >> "$list_file"
    continue
  fi

  # Proceed with full encoding
  echo "▶️ Full encoding: $base"
  if ! ffmpeg -y -hwaccel cuda -hide_banner -loglevel error -stats -i "$f" -map 0 -c:v hevc_nvenc -preset p3 -rc vbr -cq 30 -c:a aac -b:a 256k -c:s copy "$tmp_file" < /dev/null; then
    echo "❌ Full encoding failed: $base"
    rm -f "$tmp_file"
    continue
  fi

  new_size=$(stat -c%s "$tmp_file")
  if (( new_size < size_bytes )); then
    # Replace original or rename depending on extension
    if [[ "$output_ext" != "$ext_lower" ]]; then
      new_file="${f%.*}.$output_ext"
      mv -f "$tmp_file" "$new_file"
      rm -f "$f"
      echo "✅ Replaced with new file: $new_file"
    else
      mv -f "$tmp_file" "$f"
      echo "✅ Replaced original file: $base"
    fi

    orig_size_fmt=$(print_size "$size_bytes")
    new_size_fmt=$(print_size "$new_size")
    reduc_percent=$(( (size_bytes - new_size) * 100 / size_bytes ))
    echo "📉 Size reduction: original = $orig_size_fmt | encoded = $new_size_fmt | reduction = ${reduc_percent}%"
  else
    echo "⚠️ Encoded file is larger, keeping original: $base"
    rm -f "$tmp_file"
  fi

  echo "$base" >> "$list_file"
done < <("${find_cmd[@]}")
