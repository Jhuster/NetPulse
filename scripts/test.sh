#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
swiftc -module-cache-path .build/module-cache src/NetPulse/Models.swift src/NetPulse/CSV.swift tests/CoreTests.swift -o .build/core-tests
.build/core-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library src/NetPulse/Models.swift src/NetPulse/CSV.swift src/NetPulse/Store.swift tests/SessionTests.swift -o .build/session-tests -framework AppKit
.build/session-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library src/NetPulse/Models.swift src/NetPulse/CSV.swift src/NetPulse/RouteModels.swift src/NetPulse/GeoDatabase.swift src/NetPulse/GeoDatabaseInstaller.swift src/NetPulse/GeoDownload.swift src/NetPulse/RouteStore.swift tests/RouteTests.swift -o .build/route-tests -framework AppKit
.build/route-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library src/NetPulse/Models.swift src/NetPulse/CSV.swift src/NetPulse/RouteModels.swift src/NetPulse/GeoDatabase.swift src/NetPulse/GeoDatabaseInstaller.swift src/NetPulse/GeoDownload.swift src/NetPulse/RouteStore.swift tests/GeoTests.swift -o .build/geo-tests -framework AppKit
.build/geo-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library src/NetPulse/Models.swift src/NetPulse/CSV.swift src/NetPulse/Store.swift src/NetPulse/RouteModels.swift src/NetPulse/GeoDatabase.swift src/NetPulse/GeoDatabaseInstaller.swift src/NetPulse/GeoDownload.swift src/NetPulse/RouteStore.swift src/NetPulse/LocalNetworkModels.swift src/NetPulse/WiFiDiagnostics.swift src/NetPulse/WiFiScanner.swift src/NetPulse/LocalNetworkReader.swift src/NetPulse/LocalNetworkStore.swift src/NetPulse/SpeedModels.swift src/NetPulse/SpeedWebEngine.swift src/NetPulse/SpeedStore.swift src/NetPulse/Workspaces.swift tests/WorkspaceTests.swift -o .build/workspace-tests -framework AppKit
.build/workspace-tests

swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library src/NetPulse/LocalNetworkModels.swift src/NetPulse/WiFiDiagnostics.swift src/NetPulse/WiFiScanner.swift src/NetPulse/LocalNetworkReader.swift src/NetPulse/LocalNetworkStore.swift tests/LocalNetworkTests.swift -o .build/local-network-tests -framework AppKit -framework Network -framework SystemConfiguration -framework CoreWLAN -framework CoreLocation
.build/local-network-tests

swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library src/NetPulse/LocalNetworkModels.swift src/NetPulse/WiFiDiagnostics.swift src/NetPulse/WiFiScanner.swift src/NetPulse/LocalNetworkReader.swift src/NetPulse/LocalNetworkStore.swift tests/WiFiDiagnosticsFixtures.swift tests/WiFiDiagnosticsTests.swift -o .build/wifi-diagnostics-tests -framework AppKit -framework Network -framework SystemConfiguration -framework CoreWLAN -framework CoreLocation
.build/wifi-diagnostics-tests

swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library src/NetPulse/Models.swift src/NetPulse/CSV.swift src/NetPulse/RouteModels.swift src/NetPulse/LocalNetworkModels.swift src/NetPulse/WiFiDiagnostics.swift src/NetPulse/LocalNetworkReader.swift src/NetPulse/SpeedModels.swift src/NetPulse/SpeedWebEngine.swift src/NetPulse/SpeedStore.swift tests/SpeedTests.swift -o .build/speed-tests -framework AppKit -framework WebKit
.build/speed-tests
