#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
if [[ ! -x "$GOBIN/gomobile" || ! -x "$GOBIN/gobind" ]]; then
  "$TAILCAT_ROOT/Scripts/bootstrap.sh"
fi
cd "$TAILCAT_ROOT/Bridge"
go mod download
go mod verify
python3 "$TAILCAT_ROOT/Scripts/verify-upstream-copy.py"
"$TAILCAT_ROOT/Scripts/generate-notices.sh"
TAILCAT_BIND_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/swift-tailcat-bind.XXXXXX")"
trap 'rm -rf "$TAILCAT_BIND_TEMP"' EXIT
python3 "$TAILCAT_ROOT/Scripts/snapshot-bridge.py" "$TAILCAT_BIND_TEMP/Bridge"
cd "$TAILCAT_BIND_TEMP/Bridge"
TAILCAT_TAGS="$(cat build-tags.txt)"
gomobile bind \
  -target=ios/arm64,iossimulator/arm64,iossimulator/amd64,macos/arm64,macos/amd64 \
  -iosversion=16.0 -macosversion=13.0 \
  -trimpath -ldflags='-s -w' -tags="$TAILCAT_TAGS" \
  -o "$TAILCAT_ROOT/Artifacts/TailcatCore.xcframework" ./mobile
python3 - "$TAILCAT_ROOT/Bridge" "$TAILCAT_BIND_TEMP/bridge-snapshot.json" <<'PY'
import hashlib, json, pathlib, sys
root, manifest = map(pathlib.Path, sys.argv[1:])
for path, sha in json.loads(manifest.read_text()).items():
    assert hashlib.sha256((root / path).read_bytes()).hexdigest() == sha, "Source changed during bind: " + path
PY
cp "$TAILCAT_ROOT/LICENSE" "$TAILCAT_ROOT/Artifacts/TailcatCore.xcframework/LICENSE"
cp "$TAILCAT_ROOT/THIRD_PARTY_NOTICES.md" "$TAILCAT_ROOT/Artifacts/TailcatCore.xcframework/THIRD_PARTY_NOTICES.md"
python3 "$TAILCAT_ROOT/Scripts/package-artifact.py"
