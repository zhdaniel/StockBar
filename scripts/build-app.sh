#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_path="${STOCKBAR_BUILD_PATH:-.build}"
app_version="${STOCKBAR_VERSION:-$(cat VERSION)}"
build_number="${STOCKBAR_BUILD_NUMBER:-7}"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
    echo "Invalid app version or build number" >&2
    exit 1
fi
swift build -c release --scratch-path "$build_path"
bin_path="$(swift build -c release --scratch-path "$build_path" --show-bin-path)"
app_path="$PWD/dist/StockBar.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/StockBar" "$app_path/Contents/MacOS/StockBar"
cp "$PWD/Assets/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp "$PWD/Assets/SupportQR.jpg" "$app_path/Contents/Resources/SupportQR.jpg"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.stockbar.app</string>
<key>CFBundleName</key><string>StockBar</string>
<key>CFBundleDisplayName</key><string>StockBar</string>
<key>CFBundleExecutable</key><string>StockBar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
echo "$app_path"
