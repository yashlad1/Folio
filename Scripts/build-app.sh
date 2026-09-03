#!/bin/bash
#
# Assembles Folio.app from the SwiftPM executable.
#
# SwiftPM only ever produces a bare binary, but Folio needs a real bundle: the
# renderer loads its assets from Contents/Resources/web, UserDefaults keys off
# the bundle identifier, and Finder needs Info.plist to hand over .md and .pdf
# files. This script is the missing packaging step.
#
# Usage: Scripts/build-app.sh [--debug] [--run]
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG=release
LAUNCH=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --run)   LAUNCH=1 ;;
        -h|--help)
            sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "build-app: unknown option '$arg'" >&2
            exit 1
            ;;
    esac
done

APP="$ROOT/build/Folio.app"
CONTENTS="$APP/Contents"

# 1. Compile.
echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Folio"
[ -x "$BIN" ] || { echo "build-app: no executable at $BIN" >&2; exit 1; }

# 2. Icon. Regenerated whenever its source outruns the artifact.
if [ ! -f Resources/AppIcon.icns ] || [ Scripts/make-icon.swift -nt Resources/AppIcon.icns ]; then
    echo "==> Generating icon"
    swift Scripts/make-icon.swift
fi

# 3. Lay out the bundle from scratch, so a removed file never lingers.
echo "==> Assembling $(basename "$APP")"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/Folio"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# The renderer's assets. FolioSchemeHandler serves folio://app/* out of here.
cp -R Web "$CONTENTS/Resources/web"

# 4. Sign. Ad-hoc is enough to run locally and to keep the bundle from being
#    killed for a stale signature after the copy above.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null

codesign --verify "$APP" || { echo "build-app: signature verification failed" >&2; exit 1; }

echo "==> Built $APP"

if [ "$LAUNCH" -eq 1 ]; then
    echo "==> Launching"
    open "$APP"
fi
