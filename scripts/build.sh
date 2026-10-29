#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache release/NetPulse.app/Contents/MacOS
swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" src/NetPulse/*.swift -o release/NetPulse.app/Contents/MacOS/NetPulse -framework SwiftUI -framework Charts -framework AppKit
cat > release/NetPulse.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NetPulse</string>
<key>CFBundleIdentifier</key><string>com.netpulse.desktop</string>
<key>CFBundleName</key><string>NetPulse</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - release/NetPulse.app
printf 'Built: %s/release/NetPulse.app\n' "$PWD"
