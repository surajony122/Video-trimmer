#!/usr/bin/env python3
"""Shrink a video to under a size limit (default 380 MB) using ffmpeg.

Modes:
  compress (default)  re-encode the whole video at a bitrate that fits (two-pass H.264)
  cut                 keep original quality, truncate the video where the size limit is hit

Examples:
  fit_size.py big.mp4
  fit_size.py big.mp4 --mode cut -o first_part.mp4
  fit_size.py big.mp4 --max-size 100        # limit in MB
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

MB = 1000 * 1000  # decimal MB: anything under this is also under the same number of MiB
SAFETY = 0.95     # aim 5% below the limit to absorb container overhead / rate-control drift
AUDIO_KBPS = 128


def probe_duration(path: str) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", path],
        capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        sys.exit(f"Could not read duration of {path}")


def has_audio(path: str) -> bool:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
         "stream=index", "-of", "csv=p=0", path], capture_output=True, text=True)
    return bool(out.stdout.strip())


def run(cmd):
    print("Running:", " ".join(cmd))
    return subprocess.call(cmd)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Get a video under a size limit.")
    p.add_argument("input")
    p.add_argument("-o", "--output", help="default: <input>_fit.mp4")
    p.add_argument("--max-size", type=float, default=380, help="limit in MB (default 380)")
    p.add_argument("--mode", choices=["compress", "cut"], default="compress")
    p.add_argument("-y", "--overwrite", action="store_true")
    args = p.parse_args(argv)

    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        p.error("ffmpeg/ffprobe not found on PATH")
    if not os.path.isfile(args.input):
        p.error(f"input file not found: {args.input}")
    output = args.output or os.path.splitext(args.input)[0] + "_fit.mp4"
    if os.path.exists(output) and not args.overwrite:
        p.error(f"{output} exists (use -y to overwrite)")

    limit = int(args.max_size * MB)
    size = os.path.getsize(args.input)
    if size < limit:
        print(f"{args.input} is already {size / MB:.1f} MB, under {args.max_size:g} MB. Nothing to do.")
        return 0

    target = int(limit * SAFETY)
    base = ["ffmpeg", "-hide_banner", "-y" if args.overwrite else "-n"]

    if args.mode == "cut":
        rc = run(base + ["-i", args.input, "-map", "0", "-c", "copy", "-fs", str(target), output])
    else:
        dur = probe_duration(args.input)
        audio = has_audio(args.input)
        a_kbps = AUDIO_KBPS if audio else 0
        v_kbps = int(target * 8 / dur / 1000) - a_kbps
        if v_kbps < 100:
            sys.exit(f"Video is {dur:.0f}s long; fitting it in {args.max_size:g} MB leaves only "
                     f"{v_kbps} kbps. Use --mode cut instead.")
        print(f"Duration {dur:.0f}s -> video bitrate {v_kbps} kbps")
        a_args = ["-c:a", "aac", "-b:a", f"{a_kbps}k"] if audio else ["-an"]
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "pass")
            vopts = ["-c:v", "libx264", "-b:v", f"{v_kbps}k", "-maxrate", f"{int(v_kbps * 1.5)}k",
                     "-bufsize", f"{v_kbps * 2}k", "-pix_fmt", "yuv420p", "-passlogfile", log]
            rc = run(base + ["-i", args.input, *vopts, "-pass", "1", "-an", "-f", "null", os.devnull])
            if rc == 0:
                rc = run(base + ["-i", args.input, *vopts, "-pass", "2", *a_args,
                                 "-movflags", "+faststart", output])
    if rc != 0:
        return rc

    final = os.path.getsize(output)
    print(f"Saved {output}: {final / MB:.1f} MB")
    if final >= limit:
        print(f"WARNING: result is not under {args.max_size:g} MB", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
