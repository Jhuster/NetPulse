#!/bin/bash
# Build the production views with deterministic screenshot fixtures; no public probes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/readme-preview .build/module-cache
python3 - <<'PY'
from pathlib import Path
app = Path('src/NetPulse/App.swift').read_text()
assert app.count('@main struct NetPulseApp') == 1
Path('.build/readme-preview/App.swift').write_text(app.replace('@main struct NetPulseApp', 'struct NetPulseApp'))
workspaces = Path('src/NetPulse/Workspaces.swift').read_text()
assert workspaces.count('let local = LocalNetworkStore()') == 1
Path('.build/readme-preview/Workspaces.swift').write_text(workspaces.replace('let local = LocalNetworkStore()', 'let local = ReadmeFixtures.makeLocal()'))
PY
sources=()
for file in src/NetPulse/*.swift; do
    case "$file" in src/NetPulse/App.swift|src/NetPulse/Workspaces.swift) ;; *) sources+=("$file") ;; esac
done
app_dir=".build/NetPulseShowcase.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swiftc -target "$(uname -m)-apple-macosx14.0" -swift-version 5 -module-cache-path .build/module-cache -parse-as-library "${sources[@]}" .build/readme-preview/App.swift .build/readme-preview/Workspaces.swift tests/ReadmePreview.swift tests/WiFiDiagnosticsFixtures.swift -o "$app_dir/Contents/MacOS/NetPulse" -framework SwiftUI -framework Charts -framework AppKit -framework Network -framework SystemConfiguration -framework CoreWLAN -framework CoreLocation -framework WebKit
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NetPulse</string>
<key>CFBundleIdentifier</key><string>com.netpulse.showcase</string>
<key>CFBundleName</key><string>NetPulse Demo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :NetPulsePreviewRoot string $PWD" "$app_dir/Contents/Info.plist"
if [ -f assets/NetPulse.icns ]; then
    cp assets/NetPulse.icns "$app_dir/Contents/Resources/NetPulse.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string NetPulse.icns' "$app_dir/Contents/Info.plist"
fi
codesign --force --sign - "$app_dir"
printf 'Built screenshot harness: %s/%s\n' "$PWD" "$app_dir"
