#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
build="${1:-$PWD/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
app="$staging/ClipNotes.app"
mkdir -p "$app/Contents/MacOS" "$build/cache"
arch="$(uname -m)"
xcrun swiftc -swift-version 6 -O -target "$arch-apple-macos26.0" \
  -module-cache-path "$build/cache" ./*.swift -o "$app/Contents/MacOS/ClipNotes"
cp -X Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto --norsrc "$app" "$build/ClipNotes.app"
codesign --verify --strict "$build/ClipNotes.app"
printf '%s\n' "$build/ClipNotes.app"
