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
