#!/bin/bash
#
# Runs Folio's test suite.
#
# The Command Line Tools ship neither XCTest nor swift-testing, so `swift test`
# is unavailable. The suite is instead an executable compiled against the real
# sources — every file under Sources/Folio except the @main entry point, which
# would collide with the test runner's own.
#
# Usage: Scripts/test.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="$(mktemp -d)/folio-tests"

# Built with a read loop rather than mapfile: macOS ships bash 3.2.
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done \
    < <(find Sources/Folio -name '*.swift' ! -name 'FolioApp.swift' | sort)

CASES=()
while IFS= read -r file; do CASES+=("$file"); done \
    < <(find Tests -name '*.swift' ! -name 'main.swift' | sort)

echo "==> Compiling ${#SOURCES[@]} source files and ${#CASES[@]} test files"
swiftc -swift-version 5 -o "$BIN" "${SOURCES[@]}" "${CASES[@]}" Tests/main.swift

echo "==> Running"
# The renderer's assets live beside the sources when not running from a bundle.
FOLIO_WEB_ROOT="$ROOT/Web" "$BIN"
