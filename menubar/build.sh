#!/bin/sh
# Build Rex Reviewer.app into ~/Applications, sign it for this Mac, and
# (re)start it. Run it again after pulling changes.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
app="$HOME/Applications/Rex Reviewer.app"

swift build -c release --package-path "$here"
bin="$(swift build -c release --package-path "$here" --show-bin-path)/RexReviewer"

pkill -x RexReviewer 2>/dev/null || true
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/RexReviewer"

cat >"$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>io.github.captjt.rex-reviewer</string>
  <key>CFBundleName</key>
  <string>Rex Reviewer</string>
  <key>CFBundleDisplayName</key>
  <string>Rex Reviewer</string>
  <key>CFBundleExecutable</key>
  <string>RexReviewer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.3.0</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

# Ad hoc: signed for this Mac only. Turn on Open at Login from the app's menu.
codesign --force --sign - "$app"
open "$app"
echo "installed $app"
