#!/bin/bash
# Build a native-architecture development app without requiring XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
swift scripts/make-icon.swift
BIN_DIR="$(swift build -c release --show-bin-path)"
APP='build/ClipStack.app'
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClipStack" "$APP/Contents/MacOS/ClipStack"
cp Resources/ClipStack.icns "$APP/Contents/Resources/ClipStack.icns"
# SwiftPM's generated GRDB resource accessor resolves its bundle next to the executable.
for resource in "$BIN_DIR"/*.bundle; do
  [[ -d "$resource" ]] || continue
  ditto "$resource" "$APP/Contents/MacOS/$(basename "$resource")"
  codesign --force --sign - "$APP/Contents/MacOS/$(basename "$resource")"
done
python3 - "$APP" <<'PY'
import plistlib, sys
from pathlib import Path
with open('Resources/Info.plist', 'rb') as source:
    info = plistlib.load(source)
info.update(CFBundleExecutable='ClipStack', CFBundleIdentifier='com.quocfe.ClipStack',
            CFBundleShortVersionString='0.1.0', CFBundleVersion='2')
with (Path(sys.argv[1]) / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump(info, output)
PY
codesign --force --sign - --options runtime --entitlements Resources/ClipStack.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built: $APP (local development signature)"
