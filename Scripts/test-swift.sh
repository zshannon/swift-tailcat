#!/usr/bin/env bash
set -euo pipefail
# Owned maintainer validation uses the ignored binary fixture.
export TAILCAT_LOCAL_ARTIFACT=1
source "$(dirname "$0")/environment.sh"
cd "$TAILCAT_ROOT/Bridge"
go build -tags="$(cat build-tags.txt)" -o "$GOBIN/tailcat-fixture" ./mobile/fixture/cmd
go install -tags="$(cat build-tags.txt)" "github.com/tailscale/tailcat/cmd/tailcat@$TAILCAT_UPSTREAM_VERSION"
mv "$GOBIN/tailcat" "$GOBIN/tailcat-cli"
cd "$TAILCAT_ROOT"
TAILCAT_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swift-tailcat-tests.XXXXXX")"
trap 'rm -rf "$TAILCAT_TEST_ROOT"' EXIT
mkdir -p "$TAILCAT_TEST_ROOT/home"
# Isolate upstream SSH host-key persistence and keep signed bundles off macOS File Provider roots.
env HOME="$TAILCAT_TEST_ROOT/home" \
  CLANG_MODULE_CACHE_PATH="$TAILCAT_ROOT/.build-tools/clang-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$TAILCAT_ROOT/.build-tools/clang-cache" \
  TAILCAT_FIXTURE_BIN="$GOBIN/tailcat-fixture" \
  TAILCAT_CLI_BIN="$GOBIN/tailcat-cli" \
  swift test --disable-sandbox \
  --cache-path "$TAILCAT_ROOT/.build-tools/swift-cache" \
  --config-path "$TAILCAT_ROOT/.build-tools/swift-config" \
  --security-path "$TAILCAT_ROOT/.build-tools/swift-security" \
  --scratch-path "$TAILCAT_TEST_ROOT/build" --jobs "${TAILCAT_BUILD_JOBS:-2}" "$@"
