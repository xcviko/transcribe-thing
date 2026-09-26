#!/usr/bin/env bash
# build-app.sh: wrap the SwiftPM executable into build/transcribe-thing.app and sign it.
#
# Usage: scripts/build-app.sh [release|debug]
# Env:
#   SIGN_IDENTITY  codesign identity (default "-" = ad-hoc). Use a stable self-signed certificate so
#                  Accessibility and Microphone grants survive rebuilds (see README); `make app` passes
#                  "transcribe-thing Developer" when the keychain has it. A self-signed identity isn't trusted
#                  (CSSMERR_TP_NOT_TRUSTED), which codesign doesn't mind.
#   VERSION        CFBundleShortVersionString (default: the one in Resources/Info.plist)
#   BUILD_NUMBER   CFBundleVersion (default: yyyymmddHHMM)
#   HARDENED=1     sign with the hardened runtime (the audio-input entitlement is already included)
#   OUT            output folder (default: build)
set -euo pipefail

CONFIG="${1:-${CONFIG:-release}}"
case "$CONFIG" in
  release|debug) ;;
  *) echo "usage: $0 [release|debug]" >&2; exit 64 ;;
esac

APP_NAME="transcribe-thing"
PRODUCT="transcribe-thing"
MIN_OS="26.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
OUT="${OUT:-$ROOT/build}"
APP="$OUT/$APP_NAME.app"
CONTENTS="$APP/Contents"
EXE="$CONTENTS/MacOS/$APP_NAME"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$PRODUCT"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Sounds" "$CONTENTS/Frameworks"
cp "$BIN_DIR/$PRODUCT" "$EXE"
printf 'APPL????' > "$CONTENTS/PkgInfo"

cp "$RES/Info.plist" "$CONTENTS/Info.plist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RES/Info.plist")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $VERSION" \
  -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$CONTENTS/Info.plist"
plutil -lint -s "$CONTENTS/Info.plist"

cp "$RES"/Sounds/*.wav "$CONTENTS/Resources/Sounds/"

shopt -s nullglob
# SwiftPM resource bundles (FluidAudio_FluidAudio.bundle, ...): the generated Bundle.module accessor looks
# in Bundle.main.resourceURL first, so an app must carry them in Contents/Resources.
for bundle in "$BIN_DIR"/*.bundle; do
  ditto "$bundle" "$CONTENTS/Resources/$(basename "$bundle")"
done
# Dynamic frameworks and dylibs (none today: FluidAudio links statically).
for framework in "$BIN_DIR"/PackageFrameworks/*.framework "$BIN_DIR"/*.framework; do
  ditto "$framework" "$CONTENTS/Frameworks/$(basename "$framework")"
done
for dylib in "$BIN_DIR"/*.dylib; do
  cp "$dylib" "$CONTENTS/Frameworks/"
done
shopt -u nullglob

# Icon: the Icon Composer package compiles to Assets.car (Liquid Glass, dark and tinted styles on macOS 26);
# the hand-drawn AppIcon.icns stays as the fallback.
cp "$RES/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
if [ -d "$RES/AppIcon.icon" ] && xcrun --find actool >/dev/null 2>&1; then
  ICON_TMP="$(mktemp -d)"
  if xcrun actool "$RES/AppIcon.icon" --compile "$ICON_TMP" --platform macosx \
       --minimum-deployment-target "$MIN_OS" --app-icon AppIcon \
       --output-partial-info-plist "$ICON_TMP/partial.plist" >"$ICON_TMP/actool.log" 2>&1 \
     && [ -f "$ICON_TMP/Assets.car" ]; then
    cp "$ICON_TMP/Assets.car" "$CONTENTS/Resources/Assets.car"
    echo "    icon: Assets.car + AppIcon.icns"
  else
    echo "    icon: actool failed, using AppIcon.icns only (see $ICON_TMP/actool.log)"
  fi
fi

# rpaths: drop absolute build-folder paths, keep the standard app one for future frameworks.
for rpath in $(otool -l "$EXE" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }'); do
  case "$rpath" in
    /*) install_name_tool -delete_rpath "$rpath" "$EXE" 2>/dev/null ;;
  esac
done
if ! otool -l "$EXE" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null
fi
rmdir "$CONTENTS/Frameworks" 2>/dev/null || true

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "==> Signing (ad-hoc)"
else
  echo "==> Signing with \"$SIGN_IDENTITY\""
fi
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
APP_SIGN_ARGS=("${SIGN_ARGS[@]}" --entitlements "$RES/transcribe-thing.entitlements")
if [ "${HARDENED:-0}" = "1" ]; then
  APP_SIGN_ARGS+=(--options runtime)
fi
# Inside-out: nested code first, the app last (never rely on --deep for signing).
shopt -s nullglob
for nested in "$CONTENTS"/Frameworks/*.framework "$CONTENTS"/Frameworks/*.dylib; do
  codesign "${SIGN_ARGS[@]}" "$nested"
done
shopt -u nullglob
codesign "${APP_SIGN_ARGS[@]}" "$APP"

# Integrity and the designated requirement only: no trust evaluation, so an untrusted self-signed identity passes.
codesign --verify --deep --strict --verbose=1 "$APP"
echo "==> Built $APP ($CONFIG, $VERSION build $BUILD_NUMBER)"
