#!/bin/sh
# Safety and reliability self-checks: builds the app code (not main.swift) with tests/main.swift and runs it.
set -e
cd "$(dirname "$0")"
out=$(mktemp -d)
swiftc -target "$(uname -m)-apple-macos14" Disk.swift Memory.swift Model.swift Views.swift Space.swift tests/main.swift -o "$out/selftest"
"$out/selftest"
