#!/bin/zsh
# Rebuilds "Video Splitter.app" in the parent folder from VideoSplitter.swift.
set -e
cd "$(dirname "$0")"
APP="../Video Splitter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library VideoSplitter.swift -o "$APP/Contents/MacOS/VideoSplitter"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Video Splitter</string>
  <key>CFBundleDisplayName</key><string>Video Splitter</string>
  <key>CFBundleIdentifier</key><string>local.video-splitter</string>
  <key>CFBundleExecutable</key><string>VideoSplitter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
