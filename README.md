# Video-trimmer

A small CLI that trims videos with ffmpeg (requires `ffmpeg` on your PATH).

```
./trim.py input.mp4 --start 00:00:10 --end 00:00:25
./trim.py input.mp4 -s 1:30 -d 20 -o clip.mp4
./trim.py input.mp4 -s 10 -e 40 --precise
```

- Times accept seconds (`90.5`) or `[HH:]MM:SS[.ms]`.
- Default mode copies streams (instant, but cuts land on keyframes).
- `--precise` re-encodes for frame-accurate cuts.

## Fit a video under 380 MB

```
./fit_size.py big.mp4                    # re-encode whole video to fit (default)
./fit_size.py big.mp4 --mode cut         # keep quality, truncate where the limit is hit
./fit_size.py big.mp4 --max-size 100     # custom limit in MB
```

- Files already under the limit are left alone.
- `compress` uses two-pass H.264 with a bitrate computed from the duration (targets 95% of the limit).
  It refuses if the video is so long that quality would be unusable and suggests `cut`.
- `cut` stream-copies, so it's instant and lossless, but you only keep the start of the video.
