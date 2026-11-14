#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
swift scripts/make-icon.swift
xcodegen generate
swift test
xcodebuild -project ClipStack.xcodeproj -scheme ClipStack -configuration Release \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  ${MARKETING_VERSION:+MARKETING_VERSION="$MARKETING_VERSION"} build
codesign --force --deep --sign - build/DerivedData/Build/Products/Release/ClipStack.app
echo 'Built: build/DerivedData/Build/Products/Release/ClipStack.app'
