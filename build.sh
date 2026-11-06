#!/bin/zsh
# Builds Softspoke.app. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Softspoke

APP=build/Softspoke.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Softspoke "$APP/Contents/MacOS/Softspoke"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Softspoke</string>
    <key>CFBundleDisplayName</key><string>Softspoke</string>
    <key>CFBundleIdentifier</key><string>local.softspoke.app</string>
    <key>CFBundleExecutable</key><string>Softspoke</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Softspoke listens only while you hold the dictation key. Audio stays on this Mac.</string>
</dict>
</plist>
PLIST

# A stable certificate lets macOS keep the app's permissions across rebuilds.
# Without one, fall back to ad-hoc signing, where each rebuild loses them.
SIGNING_NAME="Softspoke Local Signing"
if security find-certificate -c "$SIGNING_NAME" >/dev/null 2>&1; then
  codesign --force --sign "$SIGNING_NAME" --identifier local.softspoke.app "$APP"
else
  echo "No '$SIGNING_NAME' certificate. Run ./make-signing-cert.sh to create one. Using ad-hoc signing."
  codesign --force --sign - --identifier local.softspoke.app "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Softspoke.app"
  cp -R "$APP" "$HOME/Applications/Softspoke.app"
  echo "Installed to ~/Applications/Softspoke.app"
fi
