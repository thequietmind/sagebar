#!/bin/bash
# Builds build/SageBar.app. Optional environment:
#   SAGEBAR_SIGN_IDENTITY  codesigning identity; ad-hoc ("-") when unset
#   SAGEBAR_UNIVERSAL=1    build for Apple silicon and Intel instead of this Mac only
#   SAGEBAR_BUILD_NUMBER   CFBundleVersion; the git commit count when unset
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

version="$(<VERSION)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'VERSION must look like 1.2.3, not %s\n' "$version" >&2
    exit 1
fi
build_number="${SAGEBAR_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
identity="${SAGEBAR_SIGN_IDENTITY:--}"

swift_flags=(-c release --disable-sandbox --cache-path .build/cache)
if [[ "${SAGEBAR_UNIVERSAL:-}" == 1 ]]; then
    swift_flags+=(--arch arm64 --arch x86_64)
fi
swift build "${swift_flags[@]}"
binary_dir="$(swift build "${swift_flags[@]}" --show-bin-path)"

app="$project_dir/build/SageBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/SageBar" "$app/Contents/MacOS/SageBar"
ditto "$binary_dir/SageBar_SageBar.bundle" "$app/Contents/Resources/SageBar_SageBar.bundle"

# The app icon comes from one 1024 × 1024 PNG; replace Assets/AppIcon.png to change it.
icon="Assets/AppIcon.png"
icon_size="$(sips -g pixelWidth -g pixelHeight "$icon" | awk '/pixel/ {printf "%s ", $2}')"
if [[ "$icon_size" != "1024 1024 " ]]; then
    printf '%s must be 1024 × 1024 pixels, not %s\n' "$icon" "$icon_size" >&2
    exit 1
fi
iconset="build/SageBar.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for dimension in 16 32 128 256 512; do
    sips -z "$dimension" "$dimension" "$icon" --out "$iconset/icon_${dimension}x${dimension}.png" >/dev/null
    doubled=$((dimension * 2))
    sips -z "$doubled" "$doubled" "$icon" --out "$iconset/icon_${dimension}x${dimension}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/SageBar.icns"

# The bundle identifier also names SageBar's Keychain items; keep it in sync with AppInfo.identifier.
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.quietmindcreative.SageBar</string>
<key>CFBundleName</key><string>SageBar</string>
<key>CFBundleDisplayName</key><string>SageBar</string>
<key>CFBundleExecutable</key><string>SageBar</string>
<key>CFBundleIconFile</key><string>SageBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${build_number}</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Hardened runtime always; notarization also needs a secure timestamp, which only Developer ID builds request.
sign_flags=(--force --options runtime --sign "$identity")
if [[ "$identity" == "Developer ID Application"* ]]; then
    sign_flags+=(--timestamp)
fi
codesign "${sign_flags[@]}" "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s %s (%s)\n' "$app" "$version" "$build_number"
