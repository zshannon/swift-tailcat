#!/usr/bin/env bash
set -euo pipefail
# Owned maintainer validation uses the ignored binary fixture.
export TAILCAT_LOCAL_ARTIFACT=1
TAILCAT_PLATFORM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAILCAT_PLATFORM_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/swift-tailcat-platforms.XXXXXX")"
trap 'rm -rf "$TAILCAT_PLATFORM_TEMP"' EXIT
mkdir -p "$TAILCAT_PLATFORM_TEMP/dependency/Artifacts" "$TAILCAT_PLATFORM_TEMP/consumer/Sources/Probe"
# Snapshot the current source and its verified local binary, including uncommitted
# source under review. SwiftPM builds the real Dependencies product for each SDK.
cp "$TAILCAT_PLATFORM_ROOT/Package.swift" "$TAILCAT_PLATFORM_TEMP/dependency/"
cp -R "$TAILCAT_PLATFORM_ROOT/Sources" "$TAILCAT_PLATFORM_TEMP/dependency/"
cp "$TAILCAT_PLATFORM_ROOT/Artifacts/TailcatCore.xcframework.zip" "$TAILCAT_PLATFORM_TEMP/dependency/Artifacts/"
cat > "$TAILCAT_PLATFORM_TEMP/consumer/Package.swift" <<'SWIFT'
// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "PlatformProbe", platforms: [.iOS(.v16), .macOS(.v13)],
    dependencies: [.package(path: "../dependency")],
    targets: [.executableTarget(name: "Probe", dependencies: [.product(name: "Tailcat", package: "dependency")])],
    swiftLanguageModes: [.v6])
SWIFT
# Compile and link the ordinary-import runnable example for every SDK.
cp "$TAILCAT_PLATFORM_ROOT/Examples/TypedRequests.swift" "$TAILCAT_PLATFORM_TEMP/consumer/Sources/Probe/main.swift"
for row in \
  'iphoneos arm64-apple-ios16.0' \
  'iphonesimulator arm64-apple-ios16.0-simulator' \
  'iphonesimulator x86_64-apple-ios16.0-simulator' \
  'macosx arm64-apple-macos13.0' \
  'macosx x86_64-apple-macos13.0'; do
  read -r sdk target <<< "$row"
  env CLANG_MODULE_CACHE_PATH="$TAILCAT_PLATFORM_TEMP/module-cache" \
    swift build --disable-sandbox --build-system native \
    --package-path "$TAILCAT_PLATFORM_TEMP/consumer" \
    --cache-path "$TAILCAT_PLATFORM_ROOT/.build-tools/swift-cache" \
    --config-path "$TAILCAT_PLATFORM_ROOT/.build-tools/swift-config" \
    --security-path "$TAILCAT_PLATFORM_ROOT/.build-tools/swift-security" \
    --scratch-path "$TAILCAT_PLATFORM_TEMP/build" --jobs 2 \
    --triple "$target" --sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" --product Probe
  printf 'Compiled and linked Swift API: %s\n' "$target"
done
