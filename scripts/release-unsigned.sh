#!/bin/bash
# Package an ad-hoc signed universal build for GitHub Releases. It is not notarized, so
# macOS asks each user to allow it once; use scripts/release.sh when a Developer ID exists.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${RELEASE_VERSION:?Set RELEASE_VERSION, for example v0.1.0}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected version vMAJOR.MINOR.PATCH' >&2; exit 1; }
python3 scripts/validate_sql.py
MARKETING_VERSION="$VERSION" bash scripts/build.sh
APP='build/DerivedData/Build/Products/Release/ClipStack.app'
lipo "$APP/Contents/MacOS/ClipStack" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
ARCHIVE="ClipStack-$VERSION.zip"
rm -f "build/$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/$ARCHIVE"
(cd build && shasum -a 256 "$ARCHIVE" > SHA256SUMS)
cat > build/RELEASE_NOTES.md <<NOTES
## Install

1. Download \`$ARCHIVE\`, unzip it, and move **ClipStack.app** to Applications.
2. Open it. This build is not notarized by Apple, so macOS blocks the first launch:
   open **System Settings → Privacy & Security** and choose **Open Anyway**, or run
   \`xattr -dr com.apple.quarantine /Applications/ClipStack.app\`.
3. Press ⌘⇧V to open the shelf. Allow Accessibility in ClipStack's Settings for automatic paste.

Requires macOS 13 or later, Apple Silicon or Intel. Verify the download with \`SHA256SUMS\`.
NOTES
echo "Packaged build/$ARCHIVE"
