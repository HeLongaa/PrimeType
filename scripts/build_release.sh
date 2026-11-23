#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/InputType/Info.plist)"
APP_PATH="/Library/Input Methods/PrimeType.app"
OUT_DIR="$ROOT_DIR/build/release"
mkdir -p "$OUT_DIR"

echo "==> Building & installing PrimeType v${VERSION}..."
./scripts/install.sh

ZIP_PATH="$OUT_DIR/PrimeType-v${VERSION}-macos-arm64.zip"
PKG_PATH="$OUT_DIR/PrimeType-v${VERSION}.pkg"

echo "==> Creating ZIP archive: $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Creating PKG installer: $PKG_PATH"
STAGE_DIR="$(mktemp -d /tmp/primetype-pkg.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$STAGE_DIR/root/Library/Input Methods" "$STAGE_DIR/scripts"
ditto "$APP_PATH" "$STAGE_DIR/root/Library/Input Methods/PrimeType.app"

cat > "$STAGE_DIR/scripts/postinstall" <<'EOF'
#!/bin/sh
APP="/Library/Input Methods/PrimeType.app"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Register with LaunchServices
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "$APP" 2>/dev/null || true

# Restart any previous instance so macOS loads the new version
killall PrimeType 2>/dev/null || true

# Register & enable the input source as the console user
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || true)"
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
  su - "$CONSOLE_USER" -c '
    /usr/bin/swift -e "
      import Carbon
      let filter = [kTISPropertyInputSourceID as String: \"com.lumocore.inputmethod.PrimeType.pinyin\"] as CFDictionary
      if let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource], let src = list.first {
        TISEnableInputSource(src)
        TISSelectInputSource(src)
      }
    " >/dev/null 2>&1 || true
  ' &
fi
exit 0
EOF
chmod +x "$STAGE_DIR/scripts/postinstall"

pkgbuild \
  --root "$STAGE_DIR/root" \
  --scripts "$STAGE_DIR/scripts" \
  --identifier "com.lumocore.inputmethod.PrimeType.pkg" \
  --version "$VERSION" \
  --install-location "/" \
  "$PKG_PATH"

echo "==> Release artifacts ready:"
ls -lh "$ZIP_PATH" "$PKG_PATH"
