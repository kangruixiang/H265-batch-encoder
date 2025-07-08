# Video Re-encoding Script (with HEVC/AV1 Detection & Recompression)

## 📦 Description

This Bash script scans a folder (optionally recursively) for video files (`*.mkv`, `*.avi`, `*.mp4`, `*.mov`, `*.wmv`, `*.flv`) that are **not** already encoded in HEVC (H.265) or AV1 format. It performs a **10-second test encoding** to estimate final file size. If the estimated encoded file is at least **20% smaller** than the original, it performs a full re-encoding using **GPU acceleration (CUDA)** via `ffmpeg`, replacing the original file if the new one is smaller.

## 🎯 Features

- ✅ Keeps all audio tracks and subtitles
- ✅ Skips files already encoded in **HEVC** or **AV1**
- ✅ Skips files for which re-encoding will only decrease size by <20%
- ✅ Skips files **smaller than a defined minimum size (in GB)**
- ✅ Skips files with **invalid duration** or that **fail test encoding**
- ✅ Automatically avoids reprocessing files listed in `encoded.list`
- ✅ Converts output to **MKV** if input is AVI or MP4 for compatibility
- ✅ Keeps original file if re-encoded version is not smaller

## ⚙️ Requirements

- `ffmpeg` compiled with **NVENC** support (NVIDIA GPU encoding)
- `ffprobe` (usually bundled with ffmpeg)
- GNU `coreutils` (`stat`, `find`, etc.)

## 🧪 How it works

1. For each eligible video file:
   - Skip if already in HEVC or AV1
   - Skip if file size is below the `min=X` threshold
   - Skip if already listed in `encoded.list`
   - Perform a 10s GPU-accelerated test encode
   - Estimate full file size based on result
   - If estimated size is ≥80% of original, skip encoding
   - Otherwise, encode full file using `ffmpeg`
   - If the encoded file is smaller, replace the original
2. Results are logged in a file named `encoded.list` in each directory.

## 📥 Usage

```bash
./script.sh [-R] [min=X] <folder>
