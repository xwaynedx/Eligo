#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist/icon-resources}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eligo-icon.XXXXXX")"
ASSET_CATALOG="$WORK_DIR/AppIcon.xcassets"
ICONSET="$ASSET_CATALOG/AppIcon.appiconset"
COMPILE_DIR="$WORK_DIR/compiled"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$ICONSET" "$COMPILE_DIR"
cp "$ROOT_DIR/Resources/AppIcon.xcassets/Contents.json" "$ASSET_CATALOG/Contents.json"
cp "$ROOT_DIR/Resources/AppIcon.xcassets/AppIcon.appiconset/Contents.json" "$ICONSET/Contents.json"
env HOME="$ROOT_DIR/.build-home" CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache" \
  /usr/bin/swiftc \
  "$ROOT_DIR/Sources/Eligo/EligoIcon.swift" \
  "$ROOT_DIR/script/generate_app_icon.swift" \
  -o "$WORK_DIR/generate_app_icon"
"$WORK_DIR/generate_app_icon" "$ICONSET"

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/Assets.car" "$OUTPUT_DIR/AppIcon.icns"

# Capture actool output to a log instead of /dev/null so a silent failure
# (e.g. all PNGs rejected as "Ambiguous Content" → empty compile dir, exit 0)
# leaves diagnostics behind instead of an unexplained missing Assets.car.
# `|| ACTOOL_RC=$?` is deliberate: under `set -e` a bare actool call would
# abort the script before we could print the log, swallowing the diagnostics
# on a genuine non-zero failure. Capture the rc ourselves so both the
# rc=0-but-empty and rc!=0 branches reach the error message below.
ACTOOL_LOG="$WORK_DIR/actool.log"
ACTOOL_RC=0
/usr/bin/xcrun actool \
  --compile "$COMPILE_DIR" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$WORK_DIR/asset-info.plist" \
  --warnings \
  "$ASSET_CATALOG" >"$ACTOOL_LOG" 2>&1 || ACTOOL_RC=$?

# actool emits AppIcon.icns next to Assets.car; copy both so Finder and
# LaunchServices also have the classic icon resource to fall back on.
for resource in Assets.car AppIcon.icns; do
  if [[ ! -f "$COMPILE_DIR/$resource" ]]; then
    echo "Icon generation did not produce $resource (actool rc=$ACTOOL_RC)" >&2
    sed 's/^/  actool: /' "$ACTOOL_LOG" >&2 || true
    exit 1
  fi
  cp "$COMPILE_DIR/$resource" "$OUTPUT_DIR/$resource"
done

echo "Generated $OUTPUT_DIR/Assets.car and $OUTPUT_DIR/AppIcon.icns"
