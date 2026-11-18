#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/app-metadata.env"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ADHOC=false

usage() {
  cat <<'USAGE'
Usage: script/release.sh [--adhoc] [--notarize]

Creates a Release .app and ZIP with a SHA-256 checksum.

Environment:
  VERSION             Marketing version (default: VERSION file)
  BUILD_NUMBER        Positive integer build number (default: 1)
  BUNDLE_ID           Owned reverse-DNS identifier (default: io.github.xwaynedx.eligo)
  COPYRIGHT           Copyright metadata
  ARCHS               Space-separated architectures (default: arm64 x86_64)
  SIGNING_IDENTITY    Developer ID Application identity (required unless --adhoc)
  NOTARY_PROFILE      notarytool keychain profile (required with --notarize)
USAGE
}

NOTARIZE=false
while (($#)); do
  case "$1" in
    --adhoc) ADHOC=true ;;
    --notarize) NOTARIZE=true ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "VERSION must contain two or three numeric components: $VERSION" >&2
  exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "BUILD_NUMBER must be a positive integer: $BUILD_NUMBER" >&2
  exit 2
fi
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+([.][A-Za-z0-9-]+)+$ ]]; then
  echo "BUNDLE_ID must be a reverse-DNS identifier: $BUNDLE_ID" >&2
  exit 2
fi
if $ADHOC; then
  SIGNING_IDENTITY="-"
elif [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "SIGNING_IDENTITY is required for a distributable build. Use --adhoc only for local verification." >&2
  exit 2
fi
if $NOTARIZE && { $ADHOC || [[ -z "$NOTARY_PROFILE" ]]; }; then
  echo "--notarize requires Developer ID signing and NOTARY_PROFILE." >&2
  exit 2
fi

export HOME="$ROOT_DIR/.build-home"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
RELEASE_DIR="$ROOT_DIR/dist/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
EXECUTABLE="$CONTENTS/MacOS/$APP_NAME"
RESOURCES="$CONTENTS/Resources"
INFO_PLIST="$CONTENTS/Info.plist"
ARTIFACT_BASENAME="$APP_NAME-$VERSION-$BUILD_NUMBER"
ZIP_PATH="$RELEASE_DIR/$ARTIFACT_BASENAME.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

mkdir -p "$HOME" "$CLANG_MODULE_CACHE_PATH"
rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$CHECKSUM_PATH"
mkdir -p "$CONTENTS/MacOS" "$RESOURCES"

read -r -a ARCH_ARRAY <<< "$ARCHS"
BUILD_ARGS=(--configuration release --disable-sandbox)
for arch in "${ARCH_ARRAY[@]}"; do
  BUILD_ARGS+=(--arch "$arch")
done

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
cp "$BIN_DIR/$APP_NAME" "$EXECUTABLE"
chmod 755 "$EXECUTABLE"

cp "$ROOT_DIR/Resources/Info.plist" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright $COPYRIGHT" "$INFO_PLIST"

"$ROOT_DIR/script/generate_app_icon.sh" "$RESOURCES"

SIGN_ARGS=(--force --deep --options runtime --entitlements "$ROOT_DIR/Resources/Eligo.entitlements" --sign "$SIGNING_IDENTITY")
if ! $ADHOC; then
  SIGN_ARGS+=(--timestamp)
fi
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
ENTITLEMENTS_OUTPUT="$(/usr/bin/codesign -d --entitlements :- "$APP_BUNDLE" 2>&1)"
if /usr/bin/grep -q 'get-task-allow' <<< "$ENTITLEMENTS_OUTPUT"; then
  echo "Release signature unexpectedly contains get-task-allow." >&2
  exit 1
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if $NOTARIZE; then
  /usr/bin/xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
fi

# Record only the artifact name so `shasum -c` works next to the downloaded
# ZIP on any machine and the manifest never leaks this checkout's path.
( cd "$RELEASE_DIR" && /usr/bin/shasum -a 256 "$ARTIFACT_BASENAME.zip" > "$ARTIFACT_BASENAME.zip.sha256" )

echo "Release app: $APP_BUNDLE"
echo "Release ZIP: $ZIP_PATH"
echo "SHA-256: $(cut -d ' ' -f 1 "$CHECKSUM_PATH")"
if $ADHOC; then
  echo "Local validation only: the app uses an ad-hoc signature and cannot pass public Gatekeeper checks."
elif ! $NOTARIZE; then
  echo "Signed but not notarized. Re-run with --notarize and NOTARY_PROFILE before public distribution."
fi
