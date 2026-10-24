#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: build-ipa.sh YouTube.app YTzoom.dylib [output.ipa]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$(cd "$1" && pwd)"
DYLIB="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
OUTPUT="${3:-$PWD/YTzoom_YouTube.ipa}"
if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$PWD/$OUTPUT"
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

test -d "$APP"
test -f "$DYLIB"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/YouTube.app"
(
  cd "$WORK"
  zip -qry "$WORK/baseline.ipa" Payload
)
bash "$ROOT/Scripts/sideload-repack.sh" "$WORK/baseline.ipa" "$DYLIB" "$OUTPUT"
