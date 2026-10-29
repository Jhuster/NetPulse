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
swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library src/NetPulse/Models.swift src/NetPulse/CSV.swift src/NetPulse/Store.swift src/NetPulse/RouteModels.swift src/NetPulse/GeoDatabase.swift src/NetPulse/GeoDatabaseInstaller.swift src/NetPulse/GeoDownload.swift src/NetPulse/RouteStore.swift src/NetPulse/Workspaces.swift tests/WorkspaceTests.swift -o .build/workspace-tests -framework AppKit
.build/workspace-tests
