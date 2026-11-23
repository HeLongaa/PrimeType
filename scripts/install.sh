#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building PrimeType.app (Release)..."
xcodebuild \
  -project InputType.xcodeproj \
  -scheme InputType \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  build

APP_SRC="build/DerivedData/Build/Products/Release/PrimeType.app"
APP_DST="/Library/Input Methods/PrimeType.app"
LEGACY_DST="/Library/Input Methods/InputType.app"
OLD_USER_DST="${HOME}/Library/Input Methods/InputType.app"
OLD_USER_PRIME_DST="${HOME}/Library/Input Methods/PrimeType.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Stage and sign before replacing so live apps never observe a half-written bundle.
# Prefer the persistent local code-signing certificate so macOS TCC (Accessibility / Microphone)
# binds to the certificate identity instead of per-build ad-hoc CDHash and survives updates.
SIGN_IDENTITY="-"
if security find-identity -p codesigning "${HOME}/Library/Keychains/login.keychain-db" 2>/dev/null | grep -q "PrimeType Local Dev"; then
  SIGN_IDENTITY="PrimeType Local Dev"
fi
echo "==> Signing PrimeType.app with identity: ${SIGN_IDENTITY}"

STAGE_DIR="$(mktemp -d /tmp/primetype-stage.XXXXXX)"
trap 'rm -rf "${STAGE_DIR}"' EXIT
cp -R "${APP_SRC}" "${STAGE_DIR}/PrimeType.app"
chmod -R a+rX "${STAGE_DIR}/PrimeType.app"
codesign --force --deep --sign "${SIGN_IDENTITY}" "${STAGE_DIR}/PrimeType.app"

# Remove Xcode build directory copies and legacy bundle from LaunchServices
"${LSREG}" -u "${ROOT_DIR}/build/DerivedData/Build/Products/Debug/InputType.app" 2>/dev/null || true
"${LSREG}" -u "${ROOT_DIR}/build/DerivedData/Build/Products/Release/InputType.app" 2>/dev/null || true
"${LSREG}" -u "${ROOT_DIR}/build/DerivedData/Build/Products/Debug/PrimeType.app" 2>/dev/null || true
"${LSREG}" -u "${ROOT_DIR}/build/DerivedData/Build/Products/Release/PrimeType.app" 2>/dev/null || true

# Check if PrimeType is already registered in macOS TIS (distinguishes first install vs hot update)
ALREADY_REGISTERED="$(swift -e '
import Carbon
let list = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
var found = false
for s in list {
    if let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) {
        let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        if id == "com.lumocore.inputmethod.PrimeType.pinyin" { found = true; break }
    }
}
print(found ? "yes" : "no")
')"

echo "==> Deploying to ${APP_DST}..."
rm -rf "${OLD_USER_DST}" "${OLD_USER_PRIME_DST}"
if [ -d "${APP_DST}" ] && [ -w "${APP_DST}" ]; then
  rsync -a --delete "${STAGE_DIR}/PrimeType.app/" "${APP_DST}/"
  chmod -R a+rX "${APP_DST}"
else
  sudo rm -rf "${APP_DST}"
  sudo cp -R "${STAGE_DIR}/PrimeType.app" "${APP_DST}"
  sudo chown -R "$(id -un):staff" "${APP_DST}"
  sudo chmod -R a+rX "${APP_DST}"
fi

if [ -d "${LEGACY_DST}" ]; then
  "${LSREG}" -u "${LEGACY_DST}" 2>/dev/null || true
  if [ -w "/Library/Input Methods" ]; then
    rm -rf "${LEGACY_DST}"
  else
    sudo rm -rf "${LEGACY_DST}" || true
  fi
fi

"${LSREG}" -f -R "${APP_DST}"
touch "${APP_DST}"

if [ "${ALREADY_REGISTERED}" = "no" ]; then
  echo "==> First-time PrimeType install detected: rebuilding macOS TIS IntlDataCache..."
  CACHE_DIR="$(getconf DARWIN_USER_CACHE_DIR)"
  rm -f "${CACHE_DIR}/com.apple.IntlDataCache.le" "${CACHE_DIR}/com.apple.IntlDataCache.le.kbdx"
  swift -e '
  import Carbon
  import Foundation
  _ = TISRegisterInputSource(URL(fileURLWithPath: "/Library/Input Methods/PrimeType.app") as CFURL)
  let all = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
  for s in all {
      if let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) {
          let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
          if id == "com.lumocore.inputmethod.PrimeType" || id == "com.lumocore.inputmethod.PrimeType.pinyin" {
              _ = TISEnableInputSource(s)
          }
      }
  }
  '
  killall TextInputMenuAgent 2>/dev/null || true
  killall KeyboardSettings 2>/dev/null || true
else
  echo "==> Hot-updating live PrimeType (keeping imklaunchagent alive for all running apps)..."
fi

killall -TERM InputType 2>/dev/null || true
killall -TERM PrimeType 2>/dev/null || true
rm -rf "${HOME}/Library/Saved Application State/com.lumocore.inputmethod.PrimeType.savedState" 2>/dev/null || true
sleep 0.2

echo "==> Running Rime smoke test..."
"${APP_DST}/Contents/MacOS/PrimeType" --smoke-test

# Launch PrimeType silently in the background (window restoration is disabled and
# applicationShouldHandleReopen ignores launches unless Settings is already open)
# so IMKServer registers its Mach port before we refresh the active input source.
open -g "${APP_DST}"
sleep 0.5

# Broadcast an input-source refresh bounce (ABC -> PrimeType) and pump the run loop
# so macOS TIS flushes the IPC and rebinds every running app to the new PrimeType process.
swift -e '
import Carbon
import Foundation

func sourceID(_ src: TISInputSource) -> String? {
    guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

let all = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
for s in all {
    if let id = sourceID(s), id == "com.lumocore.inputmethod.PrimeType" || id == "com.lumocore.inputmethod.PrimeType.pinyin" {
        _ = TISEnableInputSource(s)
    }
}

let enabled = TISCreateInputSourceList([kTISPropertyInputSourceIsEnabled: true] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
let fallback = enabled.first { id in
    guard let s = sourceID(id) else { return false }
    return s == "com.apple.keylayout.ABC" || s == "com.apple.keylayout.US"
}
let primeType = enabled.first { sourceID($0) == "com.lumocore.inputmethod.PrimeType.pinyin" }
if let fallback, let primeType {
    _ = TISSelectInputSource(fallback)
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    for _ in 0..<5 {
        _ = TISSelectInputSource(primeType)
        RunLoop.main.run(until: Date().addingTimeInterval(0.18))
        let active = sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) ?? ""
        if active == "com.lumocore.inputmethod.PrimeType.pinyin" {
            break
        }
    }
    let active = sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) ?? "unknown"
    print("Refreshed active IMK connection: \(active)")
}
'

echo "==> Done! Updated cleanly across all apps."
