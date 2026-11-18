#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/routing-recovery"
mkdir -p "$BUILD_DIR"
swiftc -parse-as-library -module-cache-path "$ROOT_DIR/.build/module-cache" \
    "$ROOT_DIR/Sources/Eligo/Browser.swift" \
    "$ROOT_DIR/Sources/Eligo/BundleDisplayName.swift" \
    "$ROOT_DIR/Sources/Eligo/OpenDestination.swift" \
    "$ROOT_DIR/Sources/Eligo/DomainMatcher.swift" \
    "$ROOT_DIR/Sources/Eligo/RoutingSettings.swift" \
    "$ROOT_DIR/Sources/Eligo/RoutingPreferencesRecovery.swift" \
    "$ROOT_DIR/script/repair-routing-preferences/Main.swift" \
    -o "$BUILD_DIR/repair-routing-preferences"
exec "$BUILD_DIR/repair-routing-preferences" "$@"
