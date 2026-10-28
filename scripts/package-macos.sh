#!/bin/bash
# Builds a Finder-friendly disk image, preserving framework symlinks and signatures.
set -euo pipefail
cd "$(dirname "$0")/.."

stage=$(mktemp -d "${TMPDIR:-/tmp}/ListenAndRecord-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto build/ListenAndRecord.app "$stage/ListenAndRecord.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname ListenAndRecord -srcfolder "$stage" \
    -format UDZO -ov build/ListenAndRecord.dmg
hdiutil verify build/ListenAndRecord.dmg
