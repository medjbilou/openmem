#!/bin/sh
# Safety self-checks: builds the disk code with tests/main.swift and runs it.
set -e
cd "$(dirname "$0")"
out=$(mktemp -d)
swiftc -target "$(uname -m)-apple-macos14" Disk.swift Memory.swift tests/main.swift -o "$out/selftest"
"$out/selftest"
