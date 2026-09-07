#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for variable in APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_ID APPLE_APP_PASSWORD RELEASE_VERSION RUNNER_TEMP; do
  [[ -n "${!variable:-}" ]] || { echo "Missing release configuration: $variable" >&2; exit 1; }
done
VERSION="${RELEASE_VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected version vMAJOR.MINOR.PATCH' >&2; exit 1; }
KEYCHAIN="$RUNNER_TEMP/clipstack-signing.keychain-db"
CERTIFICATE="$RUNNER_TEMP/clipstack-certificate.p12"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -f "$CERTIFICATE"
}
trap cleanup EXIT
printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$CERTIFICATE"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERTIFICATE" -P "$APPLE_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
swift scripts/make-icon.swift
xcodegen generate
swift test
python3 scripts/validate_sql.py
xcodebuild -project ClipStack.xcodeproj -scheme ClipStack -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/ClipStack.xcarchive \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$VERSION" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" ENABLE_HARDENED_RUNTIME=YES archive
APP='build/ClipStack.xcarchive/Products/Applications/ClipStack.app'
lipo "$APP/Contents/MacOS/ClipStack" -verify_arch arm64 x86_64
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" build/notarization.zip
xcrun notarytool submit build/notarization.zip --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/ClipStack-$VERSION.zip"
(cd build && shasum -a 256 "ClipStack-$VERSION.zip" > SHA256SUMS)
