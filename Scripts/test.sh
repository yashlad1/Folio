#!/bin/bash
#
# Runs Folio's test suite.
#
# Xcode is installed but `xcode-select` still points at the Command Line Tools,
# which carry no XCTest. Rather than require `sudo xcode-select -s`, this sets
# DEVELOPER_DIR for the duration of the run.
#
# Usage: Scripts/test.sh [extra swift test arguments]
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! xcrun --find xctest >/dev/null 2>&1; then
    for candidate in /Applications/Xcode*.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi

if ! xcrun --find xctest >/dev/null 2>&1; then
    echo "test: no XCTest available. Install Xcode, or point DEVELOPER_DIR at it." >&2
    exit 1
fi

# Outside an app bundle the renderer cannot find its own assets, and the
# markdown-to-PDF tests need them.
export FOLIO_WEB_ROOT="$ROOT/Web"

echo "==> Using $(basename "$(dirname "$(dirname "${DEVELOPER_DIR:-$(xcode-select -p)}")")")"
swift test "$@"
