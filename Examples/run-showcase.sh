#!/usr/bin/env bash
# Walks through swift-packable's main use cases on the example packages.
# Usage: Examples/run-showcase.sh   (outputs go to Examples/build)
set -euo pipefail

EXAMPLES="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$EXAMPLES")"
BUILD="$EXAMPLES/build"
TOOL="$ROOT/.build/release/swift-packable"
KIT="$EXAMPLES/ShowcaseKit"
APP="$EXAMPLES/ShowcaseApp"

step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
run() { printf '\033[2m$ %s\033[0m\n' "$*"; "$@"; }

step "0. Build swift-packable"
run swift build -c release --package-path "$ROOT"
rm -rf "$BUILD"
mkdir -p "$BUILD"

step "1. Inspect a package: products, declared platforms, slices built by default"
run "$TOOL" list "$KIT"

step "2. Package every library product for the manifest's platforms"
run "$TOOL" "$KIT" -o "$BUILD/ShowcaseKit-binary"
echo
cat "$BUILD/ShowcaseKit-binary/Package.swift"

step "3. Use the binaries from a client package"
# ShowcaseKit's resources come with the binary package (a resource target next to its
# XCFramework), so SwiftPM installs the bundle and Bundle.module finds it.
run swift run -c release --package-path "$APP" ShowcaseApp
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
run swift build --package-path "$APP" --triple arm64-apple-ios15.0-simulator --sdk "$SIM_SDK"

step "4. One product, one platform, one architecture"
run "$TOOL" "$KIT" -p ShowcaseStats --platform macos --arch macos=arm64 -o "$BUILD/ShowcaseStats-macos"

step "5. Release: zipped XCFrameworks, SwiftPM checksums, remote URLs"
run "$TOOL" "$KIT" --zip --base-url https://example.com/showcasekit/1.0.0 \
  --framework-version 1.0.0 -o "$BUILD/ShowcaseKit-release"
echo
cat "$BUILD/ShowcaseKit-release/Package.swift"

step "6. Switch a dependency between source and binary with packable.yml"
SWITCH="$EXAMPLES/SwitchableApp"
run cat "$SWITCH/packable.yml"
run "$TOOL" generate --package-path "$SWITCH"
run swift run --package-path "$SWITCH" SwitchableApp

# Binary mode: no `binary:` location is declared, so ShowcaseKit is packaged on demand.
run "$TOOL" use binary ShowcaseKit --package-path "$SWITCH"
run swift run --package-path "$SWITCH" SwitchableApp

# Back to source, then binary again: the cached binary is reused, nothing is rebuilt.
run "$TOOL" use source ShowcaseKit --package-path "$SWITCH"
run "$TOOL" use binary ShowcaseKit --package-path "$SWITCH"
# Leave the example in source mode, as committed.
run "$TOOL" use source ShowcaseKit --package-path "$SWITCH"

step "Done. Outputs are in $BUILD"
