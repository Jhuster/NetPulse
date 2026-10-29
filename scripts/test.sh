#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
swiftc -module-cache-path .build/module-cache src/NetPulse/Models.swift src/NetPulse/CSV.swift tests/CoreTests.swift -o .build/core-tests
.build/core-tests
swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library src/NetPulse/Models.swift src/NetPulse/CSV.swift src/NetPulse/Store.swift tests/SessionTests.swift -o .build/session-tests -framework AppKit
.build/session-tests
