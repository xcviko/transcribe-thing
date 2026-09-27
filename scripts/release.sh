#!/usr/bin/env bash
# release.sh: build, sign and zip a release of transcribe-thing for GitHub, and draft its notes.
#
# Usage: scripts/release.sh <version>        (or: make release VERSION=x.y.z)
# Env:
#   SIGN_IDENTITY  codesign identity (default: "transcribe-thing Developer" when the keychain has it). Ad-hoc ("-")
#                  is refused: installed copies only accept updates whose signature satisfies their designated
#                  requirement, which pins that certificate.
#
# Steps: refuse on a dirty tree, a version that isn't x.y.z, or an existing tag; set CFBundleShortVersionString in
# Resources/Info.plist (a local "Release x.y.z" commit when it changes); build the release app; zip it to
# dist/transcribe-thing-<version>.zip; draft dist/release-notes-<version>.md from the commits since the previous
# tag; print the zip's SHA-256.
#
# It never pushes and never publishes. It prints the two commands that do (git push, gh release create) for you
# to read and run yourself.
set -euo pipefail

VERSION="${1:-${VERSION:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="transcribe-thing"
SIGN_CERT="transcribe-thing Developer"
INFO_PLIST="$ROOT/Resources/Info.plist"
DIST="$ROOT/dist"
cd "$ROOT"

fail() {
  echo "release: $*" >&2
  exit 1
}

[ -n "$VERSION" ] || fail "usage: scripts/release.sh <version>   (e.g. 0.2.0)"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || fail "\"$VERSION\" isn't a version like 1.2.3 (no \"v\", no suffix)"
TAG="v$VERSION"

[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes; commit or stash them first"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "release: note: releasing from \"$BRANCH\", not main" >&2

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  fail "tag $TAG already exists"
fi
# Read-only: asks GitHub whether the tag exists there. Offline, the check is skipped.
if REMOTE_TAGS="$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null)"; then
  [ -z "$REMOTE_TAGS" ] || fail "tag $TAG already exists on origin"
else
  echo "release: note: couldn't reach origin to check for $TAG" >&2
fi

if [ -z "${SIGN_IDENTITY:-}" ]; then
  if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_CERT\""; then
    SIGN_IDENTITY="$SIGN_CERT"
  else
    SIGN_IDENTITY="-"
  fi
fi
[ "$SIGN_IDENTITY" != "-" ] \
  || fail "no signing certificate: releases must be signed with \"$SIGN_CERT\" (see README), never ad-hoc"

PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
if [ "$CURRENT" != "$VERSION" ]; then
  echo "==> Info.plist $CURRENT -> $VERSION"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
  git add "$INFO_PLIST"
  git commit -q -m "Release $VERSION"
  echo "    committed \"Release $VERSION\" (local only)"
fi

SIGN_IDENTITY="$SIGN_IDENTITY" VERSION="$VERSION" "$ROOT/scripts/build-app.sh" release
APP="$ROOT/build/$APP_NAME.app"

# Installed copies accept only builds that satisfy their designated requirement: it must pin the certificate.
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
[[ "$REQUIREMENT" == *"certificate leaf"* ]] || fail "unexpected designated requirement: $REQUIREMENT"
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUILT" = "$VERSION" ] || fail "the app says $BUILT, not $VERSION"

mkdir -p "$DIST"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
echo "==> Zipping $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

NOTES="$DIST/release-notes-$VERSION.md"
if [ -f "$NOTES" ]; then
  echo "==> Keeping your notes in $NOTES"
else
  if [ -n "$PREVIOUS_TAG" ]; then
    RANGE="$PREVIOUS_TAG..HEAD"
  else
    RANGE="HEAD"
  fi
  {
    echo "## What's Changed"
    echo
    git log --no-merges --format='- %s' "$RANGE" | grep -v "^- Release $VERSION\$" || true
    if [ -n "$PREVIOUS_TAG" ]; then
      echo
      echo "**Full Changelog**: https://github.com/xcviko/transcribe-thing/compare/$PREVIOUS_TAG...$TAG"
    fi
  } > "$NOTES"
  echo "==> Drafted $NOTES from ${PREVIOUS_TAG:-the first commit}${PREVIOUS_TAG:+..HEAD}: edit it before publishing"
fi

SHA="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"
SIZE="$(stat -f %z "$ZIP")"

cat <<EOF

Release $VERSION is ready (nothing was pushed or published):
  $ZIP
  $SIZE bytes · sha256 $SHA
  signed: $REQUIREMENT
  notes: $NOTES

To publish, run these yourself:

  git push origin main
  gh release create $TAG dist/$APP_NAME-$VERSION.zip --title "transcribe-thing $VERSION" --notes-file dist/release-notes-$VERSION.md --target main

EOF
