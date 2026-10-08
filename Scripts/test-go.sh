#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
TAILCAT_GO_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/swift-tailcat-go-tests.XXXXXX")"
trap 'rm -rf "$TAILCAT_GO_TEMP"' EXIT
python3 "$TAILCAT_ROOT/Scripts/snapshot-bridge.py" "$TAILCAT_GO_TEMP/Bridge"
cd "$TAILCAT_GO_TEMP/Bridge"
go mod verify
go test -race -tags="$(cat build-tags.txt)" ./... -count=1 -timeout=180s "$@"
