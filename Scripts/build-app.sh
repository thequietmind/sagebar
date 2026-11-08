#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build -c release --disable-sandbox --cache-path .build/cache
SAGEBAR_BINARY_DIR="$(swift build -c release --disable-sandbox --cache-path .build/cache --show-bin-path)"
SAGEBAR_APP="$PROJECT_DIR/build/SageBar.app"
mkdir -p "$SAGEBAR_APP/Contents/MacOS" "$SAGEBAR_APP/Contents/Resources" build/SageBar.iconset
cp "$SAGEBAR_BINARY_DIR/SageBar" "$SAGEBAR_APP/Contents/MacOS/SageBar"
ditto "$SAGEBAR_BINARY_DIR/SageBar_SageBar.bundle" "$SAGEBAR_APP/Contents/Resources/SageBar_SageBar.bundle"

swift Scripts/Icon.swift build/icon.png
for dimension in 16 32 128 256 512; do
    sips -z "$dimension" "$dimension" build/icon.png --out "build/SageBar.iconset/icon_${dimension}x${dimension}.png" >/dev/null
    doubled=$((dimension * 2))
    sips -z "$doubled" "$doubled" build/icon.png --out "build/SageBar.iconset/icon_${dimension}x${dimension}@2x.png" >/dev/null
done
iconutil -c icns build/SageBar.iconset -o "$SAGEBAR_APP/Contents/Resources/SageBar.icns"

cat > "$SAGEBAR_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.SageBar</string>
<key>CFBundleName</key><string>SageBar</string>
<key>CFBundleDisplayName</key><string>SageBar</string>
<key>CFBundleExecutable</key><string>SageBar</string>
<key>CFBundleIconFile</key><string>SageBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --sign "${SAGEBAR_SIGN_IDENTITY:--}" "$SAGEBAR_APP"
codesign --verify --deep --strict "$SAGEBAR_APP"
printf 'Built %s\n' "$SAGEBAR_APP"
