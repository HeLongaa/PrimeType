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

echo "==> Building PrimeTypeSettings.app Helper (Release)..."
xcodebuild \
  -project InputType.xcodeproj \
  -scheme PrimeTypeSettings \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

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

BUILT_HELPER="$DERIVED_DATA/Build/Products/Release/PrimeTypeSettings.app"
BUILT_IME="$DERIVED_DATA/Build/Products/Release/PrimeType.app"
BUILT_INSTALLER="$DERIVED_DATA/Build/Products/Release/PrimeTypeInstaller.app"

echo "==> Embedding PrimeTypeSettings.app inside PrimeType.app/Contents/Helpers/..."
mkdir -p "$BUILT_IME/Contents/Helpers"
rm -rf "$BUILT_IME/Contents/Helpers/PrimeTypeSettings.app"
ditto "$BUILT_HELPER" "$BUILT_IME/Contents/Helpers/PrimeTypeSettings.app"

SIGN_ID="${PRIMETYPE_SIGN_IDENTITY:-PrimeType Local Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_ID\""; then
  codesign --force --deep --sign "$SIGN_ID" "$BUILT_IME/Contents/Helpers/PrimeTypeSettings.app"
  codesign --force --deep --sign "$SIGN_ID" "$BUILT_IME"
else
  codesign --force --deep --sign - "$BUILT_IME/Contents/Helpers/PrimeTypeSettings.app"
  codesign --force --deep --sign - "$BUILT_IME"
fi

STAGE_DIR="$(mktemp -d /tmp/primetype-installer-stage.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

STAGED_INSTALLER="$STAGE_DIR/PrimeTypeInstaller.app"
ditto "$BUILT_INSTALLER" "$STAGED_INSTALLER"
ditto "$BUILT_IME" "$STAGED_INSTALLER/Contents/Resources/PrimeType.app"

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
