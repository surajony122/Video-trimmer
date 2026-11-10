# Video Splitter

A small Mac app that cuts big videos into clips that each stay under a size limit (400 MB by default).

- Add videos with the button or by dragging them into the window.
- Click **Split Videos**, choose where to save, and get `name - part 01.mp4`, `part 02`, …
- Clips are cut without re-encoding, so quality is unchanged and it is fast. Originals are never modified.
- Works with MP4, MOV and M4V. Videos already under the limit are copied as they are.

## Build

Needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./source/build.sh
```

This creates `Video Splitter.app` next to the `source` folder.
