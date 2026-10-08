#!/usr/bin/env bash
# Source this file; task-local tools and caches never replace system tools.
set -euo pipefail
TAILCAT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAILCAT_CACHE_ROOT="${TAILCAT_CACHE_ROOT:-${TMPDIR:-/tmp}/swift-tailcat-build-cache}"
export GOCACHE="$TAILCAT_CACHE_ROOT/go-cache"
export GOMODCACHE="$TAILCAT_CACHE_ROOT/go-mod"
export GOPATH="$TAILCAT_CACHE_ROOT/go"
export GOTOOLCHAIN=go1.27.1
export GOBIN="$TAILCAT_ROOT/.build-tools/bin"
export GOMAXPROCS="${TAILCAT_BUILD_JOBS:-2}"
export GOFLAGS="-p=${TAILCAT_BUILD_JOBS:-2}"
export PATH="$GOBIN:$PATH"
mkdir -p "$GOBIN" "$GOCACHE" "$GOMODCACHE" "$GOPATH"
TAILCAT_MOBILE_VERSION=v0.0.0-20260908204917-8b95e45f8d3e
TAILCAT_UPSTREAM_VERSION=v0.7.1-0.20260929145319-b4dc28e8aa89
TAILCAT_UPSTREAM_COMMIT=b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f
