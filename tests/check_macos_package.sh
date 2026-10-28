#!/bin/bash
# Check what a user installs after opening the distributed disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

image=$(pwd)/build/ListenAndRecord.dmg
checkdir=$(mktemp -d "${TMPDIR:-/tmp}/ListenAndRecord-install.XXXXXX")
mountpoint="$checkdir/mounted"
attached=false
cleanup() {
    if "$attached"; then hdiutil detach "$mountpoint"; fi
    rm -rf "$checkdir"
}
trap cleanup EXIT

mkdir -p "$mountpoint" "$checkdir/installed"
hdiutil attach "$image" -readonly -nobrowse -mountpoint "$mountpoint"
attached=true
test "$(readlink "$mountpoint/Applications")" = /Applications
ditto "$mountpoint/ListenAndRecord.app" "$checkdir/installed/ListenAndRecord.app"
hdiutil detach "$mountpoint"
attached=false

app="$checkdir/installed/ListenAndRecord.app"
test -x "$app/Contents/MacOS/ListenAndRecord"
test -L "$app/Contents/Frameworks/whisper.framework/Versions/Current"
codesign --verify --deep --strict --verbose=2 "$app"
python3 tests/check_lifecycle.py "$app/Contents/MacOS/ListenAndRecord" "$1" "$2"
