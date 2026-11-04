#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
STAGING="$(mktemp -d /private/tmp/chatgpt-backdrop.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/ChatGPT Backdrop.app"
BUILD="$STAGING/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"
export CLANG_MODULE_CACHE_PATH="$BUILD/module-cache"
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -O \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD/module-cache" \
  -framework SwiftUI -framework AppKit -framework Security -framework ImageIO \
  "$ROOT/Sources/CDPClient.swift" "$ROOT/Sources/BackdropWindows.swift" "$ROOT/Sources/BackdropMedia.swift" "$ROOT/Sources/BackdropSettings.swift" "$ROOT/Sources/BackdropApp.swift" \
  -o "$APP/Contents/MacOS/ChatGPTBackdrop"
cp "$ROOT/Sources/theme.js" "$APP/Contents/Resources/theme.js"
if [[ -f "$ROOT/Brand/Backdrop.icns" ]]; then
  cp "$ROOT/Brand/Backdrop.icns" "$APP/Contents/Resources/Backdrop.icns"
fi
if [[ -f "$ROOT/Brand/Backdrop-AppIcon.png" ]]; then
  cp "$ROOT/Brand/Backdrop-AppIcon.png" "$APP/Contents/Resources/Backdrop-AppIcon.png"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.charlie.chatgpt-backdrop</string>
<key>CFBundleName</key><string>ChatGPT Backdrop</string>
<key>CFBundleDisplayName</key><string>ChatGPT Backdrop</string>
<key>CFBundleExecutable</key><string>ChatGPTBackdrop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Backdrop.icns</string>
<key>CFBundleShortVersionString</key><string>1.2.1</string>
<key>CFBundleVersion</key><string>11</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
if /usr/bin/xattr -p com.apple.FinderInfo "$APP" >/dev/null 2>&1; then
  /usr/bin/xattr -d com.apple.FinderInfo "$APP"
fi
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/ditto --norsrc --noextattr "$APP" "$ROOT/ChatGPT Backdrop.app"
print "Built: $ROOT/ChatGPT Backdrop.app"
