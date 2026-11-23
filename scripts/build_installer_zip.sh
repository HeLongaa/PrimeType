#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/InputType/Info.plist)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
OUT_DIR="$ROOT_DIR/build/release"
mkdir -p "$OUT_DIR"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building PrimeType.app (Release)..."
xcodebuild \
  -project InputType.xcodeproj \
  -scheme InputType \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

echo "==> Building PrimeTypeInstaller.app (Release)..."
xcodebuild \
  -project InputType.xcodeproj \
  -scheme PrimeTypeInstaller \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

BUILT_IME="$DERIVED_DATA/Build/Products/Release/PrimeType.app"
BUILT_INSTALLER="$DERIVED_DATA/Build/Products/Release/PrimeTypeInstaller.app"

STAGE_DIR="$(mktemp -d /tmp/primetype-installer-stage.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

STAGED_INSTALLER="$STAGE_DIR/PrimeTypeInstaller.app"
ditto "$BUILT_INSTALLER" "$STAGED_INSTALLER"
ditto "$BUILT_IME" "$STAGED_INSTALLER/Contents/Resources/PrimeType.app"

SIGN_ID="${PRIMETYPE_SIGN_IDENTITY:-PrimeType Local Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_ID\""; then
  echo "==> Signing embedded PrimeType.app and PrimeTypeInstaller.app with: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$STAGED_INSTALLER/Contents/Resources/PrimeType.app"
  codesign --force --sign "$SIGN_ID" "$STAGED_INSTALLER"
else
  echo "==> Ad-hoc signing PrimeTypeInstaller.app"
  codesign --force --deep --sign - "$STAGED_INSTALLER/Contents/Resources/PrimeType.app"
  codesign --force --sign - "$STAGED_INSTALLER"
fi

ZIP_PATH="$OUT_DIR/PrimeTypeInstaller-v${VERSION}.zip"
rm -f "$ZIP_PATH"
echo "==> Packaging $ZIP_PATH..."
ditto -c -k --sequesterRsrc --keepParent "$STAGED_INSTALLER" "$ZIP_PATH"

echo "==> Done! Local test archive ready:"
ls -lh "$ZIP_PATH"
