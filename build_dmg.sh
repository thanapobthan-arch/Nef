#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Running NefCopy safety tests before build..."
./test_nefcopy.sh

set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="NefCopy"
BUNDLE_ID="local.nefcopy.mac"
rm -rf .build dist
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
mkdir -p "dist/${APP_NAME}.app/Contents/MacOS"
cp "$BIN_PATH/NefCopy" "dist/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
cat > "dist/${APP_NAME}.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>${APP_NAME}</string><key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleName</key><string>${APP_NAME}</string><key>CFBundleDisplayName</key><string>${APP_NAME}</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>21.1.4</string>
<key>CFBundleVersion</key><string>2114.20</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "dist/${APP_NAME}.app"
mkdir -p dist/dmg; cp -R "dist/${APP_NAME}.app" dist/dmg/; ln -s /Applications dist/dmg/Applications
if diskutil image create from dist/dmg --volumeName "$APP_NAME" --format UDZO "dist/${APP_NAME}-Mac.dmg" >/dev/null 2>&1; then
  echo "Created DMG with diskutil image."
else
  echo "diskutil image create unavailable; using hdiutil compatibility fallback."
  hdiutil create -volname "$APP_NAME" -srcfolder dist/dmg -ov -format UDZO "dist/${APP_NAME}-Mac.dmg"
fi
rm -rf dist/dmg
echo ""; echo "Created: $(pwd)/dist/${APP_NAME}-Mac.dmg"
