#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build --disable-sandbox -c release -debug-info-format none --product MacSuperpowers
swift build --disable-sandbox -c release -debug-info-format none --product MacSuperpowersMonitorAgent
binary_directory="$(swift build --disable-sandbox -c release --show-bin-path)"
app_directory="$repository_root/dist/Mac Superpowers.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources" "$app_directory/Contents/Library/LaunchAgents"
cp "$binary_directory/MacSuperpowers" "$app_directory/Contents/MacOS/MacSuperpowers"
cp "$binary_directory/MacSuperpowersMonitorAgent" "$app_directory/Contents/MacOS/MacSuperpowersMonitorAgent"
resource_bundle="$binary_directory/MacSuperpowers_MacSuperpowers.bundle"
if [[ -d "$resource_bundle" ]]; then
  cp -R "$resource_bundle" "$app_directory/Contents/Resources/"
fi
cp "$repository_root/Sources/MacSuperpowers/Resources/PrivacyInfo.xcprivacy" \
  "$app_directory/Contents/Resources/PrivacyInfo.xcprivacy"

iconset_directory="$repository_root/dist/AppIcon.iconset"
mkdir -p "$iconset_directory"
icon_source="$repository_root/AssetsProposed/AppIcon-1024.png"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$icon_source" --out "$iconset_directory/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -s format png -z "$double_size" "$double_size" "$icon_source" --out "$iconset_directory/icon_${size}x${size}@2x.png" >/dev/null
done
python3 "$repository_root/scripts/make-icns.py" \
  "$iconset_directory" "$app_directory/Contents/Resources/AppIcon.icns"

cat > "$app_directory/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
    <key>CFBundleDisplayName</key><string>Mac Superpowers</string>
    <key>CFBundleExecutable</key><string>MacSuperpowers</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key><string>com.example.MacSuperpowers</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Mac Superpowers</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$app_directory/Contents/Library/LaunchAgents/com.macsuperpowers.monitor.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.macsuperpowers.monitor</string>
    <key>BundleProgram</key><string>Contents/MacOS/MacSuperpowersMonitorAgent</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
PLIST

# Assinatura local por padrão; uma identidade estável preserva permissões
# entre versões durante o desenvolvimento.
signing_identity="${MAC_SUPERPOWERS_SIGNING_IDENTITY:--}"
codesign --force --sign "$signing_identity" --identifier "com.example.MacSuperpowers.monitor" \
  "$app_directory/Contents/MacOS/MacSuperpowersMonitorAgent"
codesign --force --sign "$signing_identity" "$app_directory"
echo "$app_directory"
