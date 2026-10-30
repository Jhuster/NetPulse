#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-icon.sh
mkdir -p .build/module-cache release/NetPulse.app/Contents/MacOS release/NetPulse.app/Contents/Resources
icon_digest=$(shasum -a 256 assets/NetPulse.icns | cut -c1-12)
icon_name="NetPulse-${icon_digest}.icns"
cp assets/NetPulse.icns "release/NetPulse.app/Contents/Resources/${icon_name}"
swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" src/NetPulse/*.swift -o release/NetPulse.app/Contents/MacOS/NetPulse -framework SwiftUI -framework Charts -framework AppKit -framework Network -framework SystemConfiguration -framework CoreWLAN -framework CoreLocation
cat > release/NetPulse.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NetPulse</string>
<key>CFBundleIdentifier</key><string>com.netpulse.desktop</string>
<key>CFBundleName</key><string>NetPulse</string>
<key>CFBundleIconFile</key><string>NetPulse.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocationUsageDescription</key><string>仅用于读取当前 Wi-Fi 名称和接入点标识，辅助网络排障，不读取或上传 GPS 位置。</string>
<key>NSLocationWhenInUseUsageDescription</key><string>仅用于读取当前 Wi-Fi 名称和接入点标识，辅助网络排障，不读取或上传 GPS 位置。</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ${icon_name}" release/NetPulse.app/Contents/Info.plist
codesign --force --sign - release/NetPulse.app
printf 'Built: %s/release/NetPulse.app\n' "$PWD"
