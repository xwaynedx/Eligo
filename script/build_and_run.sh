#!/usr/bin/env bash
#
# Build Eligo, then install and run it (usage: see the MODE cases at
# the bottom, or run with an unknown argument for the usage line).
#
# Install side effects: the built bundle is ad-hoc signed. If the installation
# target differs, "$INSTALL_DIR/Eligo.app" is deleted and re-ditto'd; an equal
# target uses the built bundle in place. Both paths then register the selected
# bundle with LaunchServices when available. INSTALL_DIR defaults to
# /Applications, so a plain run overwrites the installed Eligo. The script also
# attempts to stop running Eligo processes before building, in every mode.
# Override INSTALL_DIR to stage somewhere else:
#
#   INSTALL_DIR="$HOME/Applications" script/build_and_run.sh
#
# Local bundles use a fresh build number by default so LaunchServices and Dock
# do not reuse metadata or icons from an earlier bundle. Override it when a
# reproducible local build number is useful:
#
#   LOCAL_BUILD_NUMBER=123 script/build_and_run.sh
#
set -euo pipefail

MODE="${1:-run}"
# Validate before any side effect: an unknown mode must not kill, build,
# or replace the installed app.
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
ROOT_DIR="$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd -P)"
source "$ROOT_DIR/script/app-metadata.env"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
# Make relative overrides independent of CDPATH before resolving symlinks.
case "$INSTALL_DIR" in
  /*) ;;
  *) INSTALL_DIR="$(pwd -P)/$INSTALL_DIR" ;;
esac
LOCAL_BUILD_NUMBER="${LOCAL_BUILD_NUMBER:-$(date -u +%s)}"

if [[ ! "$LOCAL_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "LOCAL_BUILD_NUMBER must be a positive integer: $LOCAL_BUILD_NUMBER" >&2
  exit 2
fi

DIST_DIR="$ROOT_DIR/dist"
SWIFT_HOME="$ROOT_DIR/.build-home"
MODULE_CACHE="$ROOT_DIR/.build/module-cache"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALLED_APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

mkdir -p "$SWIFT_HOME" "$MODULE_CACHE"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

env HOME="$SWIFT_HOME" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift build --disable-sandbox
BUILD_BINARY="$(env HOME="$SWIFT_HOME" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift build --disable-sandbox --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# Derive the manifest from the single canonical template (shared with
# script/release.sh); override only per-build metadata.
cp "$ROOT_DIR/Resources/Info.plist" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LOCAL_BUILD_NUMBER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright $COPYRIGHT" "$INFO_PLIST"

# Generate both compiled icon resources inside the fresh bundle before signing.
"$ROOT_DIR/script/generate_app_icon.sh" "$APP_RESOURCES"

# Service Management needs a fully signed app bundle to resolve the main app
# as a login item. Ad-hoc signing is enough for local bundle validation; the
# release script uses the user's Developer ID identity for distributable builds.
SIGNING_ENTITLEMENTS="$ROOT_DIR/Resources/Eligo.entitlements"
if [[ "$MODE" == --debug || "$MODE" == debug ]]; then
  DEBUG_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/eligo-debug-entitlements.XXXXXX")"
  trap 'rm -f "$DEBUG_ENTITLEMENTS"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cp "$SIGNING_ENTITLEMENTS" "$DEBUG_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$DEBUG_ENTITLEMENTS"
  SIGNING_ENTITLEMENTS="$DEBUG_ENTITLEMENTS"
fi
/usr/bin/codesign \
  --force \
  --deep \
  --options runtime \
  --entitlements "$SIGNING_ENTITLEMENTS" \
  --sign - \
  "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

# Resolve physical paths with macOS cd and /bin/pwd, without GNU realpath/readlink.
# Walk missing components back to an existing directory; don't create anything
# until the relationship is known, as the requested path may be inside the app.
resolve_bundle_path() {
  local path="$1" suffix="" component physical
  while [[ ! -d "$path" ]]; do
    if [[ -e "$path" || -L "$path" ]]; then
      echo "Cannot resolve bundle path (not a directory or dangling symlink): $path" >&2
      return 1
    fi
    component="$(basename "$path")"
    # '..' through a missing component has no physical directory to resolve.
    if [[ "$component" == . || "$component" == .. ]]; then
      echo "Cannot resolve traversal through a missing directory: $path" >&2
      return 1
    fi
    suffix="/$component$suffix"
    path="$(dirname "$path")"
  done
  # Bash's builtin pwd can retain alias casing on case-insensitive volumes;
  # macOS /bin/pwd returns the actual directory names for overlap comparisons.
  physical="$(cd -P -- "$path" >/dev/null && /bin/pwd -P)" || {
    echo "Cannot resolve bundle directory: $path" >&2
    return 1
  }
  printf '%s%s\n' "${physical%/}" "$suffix"
}
SOURCE_BUNDLE_PATH="$(resolve_bundle_path "$APP_BUNDLE")"
TARGET_BUNDLE_PATH="$(resolve_bundle_path "$INSTALLED_APP_BUNDLE")"
if [[ "$SOURCE_BUNDLE_PATH" == "$TARGET_BUNDLE_PATH" || "$APP_BUNDLE" -ef "$INSTALLED_APP_BUNDLE" ]]; then
  INSTALLED_APP_BUNDLE="$SOURCE_BUNDLE_PATH"
else
  # Reject overlapping trees: deleting an ancestor destroys the source, while
  # copying into a descendant would recursively copy the app into itself.
  case "$TARGET_BUNDLE_PATH/" in
    "$SOURCE_BUNDLE_PATH/"*)
      echo "Installation target is inside the built bundle: $INSTALLED_APP_BUNDLE" >&2
      exit 1
      ;;
  esac
  case "$SOURCE_BUNDLE_PATH/" in
    "$TARGET_BUNDLE_PATH/"*)
      echo "Installation target contains the built bundle: $INSTALLED_APP_BUNDLE" >&2
      exit 1
      ;;
  esac
  if ! mkdir -p "$INSTALL_DIR"; then
    echo "Cannot prepare installation directory: $INSTALL_DIR" >&2
    exit 1
  fi
  rm -rf "$INSTALLED_APP_BUNDLE"
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP_BUNDLE"
fi
/usr/bin/codesign --verify --deep --strict "$INSTALLED_APP_BUNDLE"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$INSTALLED_APP_BUNDLE" || {
    echo "Warning: LaunchServices registration failed; continuing to launch the app." >&2
  }
fi

open_app() {
  /usr/bin/open -n "$INSTALLED_APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
