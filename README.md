# H265 Video Re-encoding Script (with HEVC/AV1 Detection & Recompression)

## 📦 Description

This Bash script scans a folder (optionally recursively) for video files (`*.mkv`, `*.avi`, `*.mp4`, `*.mov`, `*.wmv`, `*.flv`) that are **not** already encoded in HEVC (H.265) or AV1 format. It performs a **5-second test encoding** to estimate final file size. If the estimated encoded file is at least **30% smaller** than the original, it performs a full re-encoding using **GPU acceleration (CUDA)** via `ffmpeg`, replacing the original file if the new one is smaller.

## 🎯 Features

- ✅ Keeps all audio tracks and subtitles
- ✅ Skips files already encoded in **HEVC** or **AV1**
- ✅ Skips files for which re-encoding will only decrease size by <20% by taking 3 small samples
- ✅ Skips files **smaller than a defined minimum size (in GB)** (accepts decimals with . or ,)
- ✅ Skips files with **invalid duration** or that **fail test encoding**
- ✅ Skips files with already low bitrate
- ✅ Automatically avoids reprocessing files listed in `encoded.list` or 'failed.list'
- ✅ Converts output to **MKV** if input is AVI or (if needed) MP4 for compatibility
- ✅ Keeps original file if re-encoded version is not smaller
- ✅ Keeps original file if duration mismatch (in case of a bug)
- ✅ Adds fast-start flag and hvc1 tags on mp4 and mov files
- ✅ Can be graciously stopped after encoding when X hours have passed (so it can be used in a nightly cron)


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
Usage:
  ./script.sh [arguments] <folder>
    List of arguments :
    -R              : Encode recursively inside subfolders
    min=X.YZ        : Ignore files smaller than X.YZ GB
    test=N          : Use N seconds for the test encode (default: 5)
    --dry-run       : Only show compatible files without encoding
    --keep-original : Keep original files instead of replacing them
    --allow-h265    : Allow files already encoded in H.265
    --allow-av1     : Allow files already encoded in AV1
    -backup /path   : Save original files to backup path (used only if not using --keep-original)
    --clean         : Remove temporary encoding files (.tmp_encode_*, .tmp_encode_test_*) from the folder(s, if combined with -R) 
    --purge         : Remove encoded.list files (.tmp_encode_*, .tmp_encode_test_*) from the folder(s, if combined with -R) 
    -h              : Show this help message
    --stop-after HH.5  : Stop after HH.5 hours of encoding (useful if in cron)

```
### How it will look

```bash
██   ██ ██████   ██████  ███████     ███████ ███    ██  ██████  ██████  ██████  ███████ ██████  
██   ██      ██ ██       ██          ██      ████   ██ ██      ██    ██ ██   ██ ██      ██   ██ 
███████  █████  ███████  ███████     █████   ██ ██  ██ ██      ██    ██ ██   ██ █████   ██████  
██   ██ ██      ██    ██      ██     ██      ██  ██ ██ ██      ██    ██ ██   ██ ██      ██   ██ 
██   ██ ███████  ██████  ███████     ███████ ██   ████  ██████  ██████  ██████  ███████ ██   ██
┌────────────────────────────────────────────┐
│  CURRENT ENCODING SETTINGS                 │
│                                            │
│  Hardware Acceleration:     true (cuda)    │
│  Video Codec:               hevc_nvenc     │
│  Audio Codec:               aac @ 256k     │
│  Constant Quality (CQ):     30             │
│  Encoding Preset:           p3             │
│  Minimum bitrate:           2000kbps       │
│  Test Clip Duration:        (3x) 5s        │
│  Minimum Size Ratio:        0.8            │
│                                            │
│  ONE-TIME SETTINGS                         │
│  Folder                     /LEGAL_VIDEOS/ │
│  Recursive                  1              │
│  Minimum Size               1,5 GB         │
│  Keep original              0              │
│  Stop after                 0h             │
│  Allow H265                 0              │
│  Allow AV1                  0              │
│  Backup directory                          │
│  Dry run                    0              │
└────────────────────────────────────────────┘
Scanning...
├── 15800 video files found / 198 will be encoded / 14 indicated as encoded / 0 indicated as failed

┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│  Task 1 / 198 : Totally Legal - S01E01 - The Beginning.mkv (2.12 GB | 00:46:27)              │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
 Encoding samples (3x 5s)
|------|----|----| @ 696s
|----|------|----| @ 1393s
|----|----|------| @ 2090s
├── Estimated size (median of 3 samples): 472.14 MB
▶️  Full encoding (00:46:27)
frame=69686 fps=129 q=24.0 Lsize=  580334kB time=00:46:27.47 bitrate=1705.5kbits/s speed=5.15x    
├── ✅ Encoding succeeded
├── ✅ Replaced original
├── ✅ Size reduced: 2.12 GB → 566.73 MB | −73%

┌───────────────────────────────────────────────────────────────────────────────────────────────────┐
│  Task 2 / 198 : Totally Legal - S01E02 - I Cant Belive It Is Free.mkv (1.56 GB | 01:21:15)        │
└───────────────────────────────────────────────────────────────────────────────────────────────────┘
 Encoding samples (3x 5s)
|------|----|----| @ 1218s
|----|------|----| @ 2437s
|----|----|------| @ 3656s
├── Estimated size (median of 3 samples): 802.86 MB
▶️  Full encoding (01:21:15)
frame=43556 fps=131 q=25.0 size=  461568kB time=00:30:16.87 bitrate=2081.1kbits/s speed=5.47x 
```
