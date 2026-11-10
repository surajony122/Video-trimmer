# Video Splitter

Two versions of the same tool: a web page that works on a phone, and a Mac app.

## Web version (phone or computer)

`index.html` is the whole thing. Host it with GitHub Pages (repo Settings → Pages → Deploy from a branch → `main`, `/ (root)`), then open the Pages address in your phone's browser.

- Choose a video, and it lists the clips it will make, each under the size limit (400 MB by default).
- Tap **Save** on a clip to make it and download it. Do one clip at a time on a phone.
- Clips are cut without re-encoding, so quality is unchanged. The video is processed on your device and is never uploaded.

## Mac app

- Add videos with the button or by dragging them into the window.
- Click **Split Videos**, choose where to save, and get `name - part 01.mp4`, `part 02`, …
- Clips are cut without re-encoding, so quality is unchanged and it is fast. Originals are never modified.
- Works with MP4, MOV and M4V. Videos already under the limit are copied as they are.

### Build

Needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./source/build.sh
```

This creates `Video Splitter.app` next to the `source` folder.
