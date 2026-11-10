#!/usr/bin/env python3
"""Video trimmer: cut a segment out of a video using ffmpeg.

Examples:
  trim.py in.mp4 --start 00:00:10 --end 00:00:25
  trim.py in.mp4 -s 1:30 -d 20 -o clip.mp4
  trim.py in.mp4 -s 10 --end 40 --precise     # re-encode for frame-accurate cuts
"""
import argparse
import os
import shutil
import subprocess
import sys


def parse_time(value: str) -> float:
    """Parse seconds ('90', '90.5') or [HH:]MM:SS[.ms] into seconds."""
    parts = value.split(":")
    if len(parts) > 3:
        raise argparse.ArgumentTypeError(f"invalid time: {value!r}")
    try:
        nums = [float(p) for p in parts]
    except ValueError:
        raise argparse.ArgumentTypeError(f"invalid time: {value!r}")
    if any(n < 0 for n in nums):
        raise argparse.ArgumentTypeError(f"time cannot be negative: {value!r}")
    seconds = 0.0
    for n in nums:
        seconds = seconds * 60 + n
    return seconds


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Trim a video with ffmpeg.")
    p.add_argument("input", help="input video file")
    p.add_argument("-s", "--start", type=parse_time, default=0.0,
                   help="start time (seconds or [HH:]MM:SS), default 0")
    g = p.add_mutually_exclusive_group()
    g.add_argument("-e", "--end", type=parse_time, help="end time")
    g.add_argument("-d", "--duration", type=parse_time, help="clip length")
    p.add_argument("-o", "--output", help="output file (default: <input>_trimmed.<ext>)")
    p.add_argument("--precise", action="store_true",
                   help="re-encode for frame-accurate cuts (slower; default is fast stream copy)")
    p.add_argument("-y", "--overwrite", action="store_true", help="overwrite output if it exists")
    args = p.parse_args(argv)

    if not shutil.which("ffmpeg"):
        p.error("ffmpeg not found on PATH")
    if not os.path.isfile(args.input):
        p.error(f"input file not found: {args.input}")

    if args.end is not None:
        if args.end <= args.start:
            p.error("--end must be after --start")
        duration = args.end - args.start
    else:
        duration = args.duration
    if duration is not None and duration <= 0:
        p.error("duration must be positive")

    root, ext = os.path.splitext(args.input)
    output = args.output or f"{root}_trimmed{ext}"
    if os.path.exists(output) and not args.overwrite:
        p.error(f"{output} exists (use -y to overwrite)")

    cmd = ["ffmpeg", "-hide_banner", "-y" if args.overwrite else "-n"]
    # Input-side seek is fast; with re-encoding it is still frame-accurate.
    cmd += ["-ss", str(args.start), "-i", args.input]
    if duration is not None:
        cmd += ["-t", str(duration)]
    cmd += ["-c", "copy", "-avoid_negative_ts", "make_zero"] if not args.precise else []
    cmd.append(output)

    print("Running:", " ".join(cmd))
    rc = subprocess.call(cmd)
    if rc == 0:
        print(f"Saved {output}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
