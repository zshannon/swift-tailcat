#!/usr/bin/env bash
set -euo pipefail
# Point at a completed SwiftPM test build (Xcode build system on macOS).
TAILCAT_API_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAILCAT_API_PRODUCTS="${1:?Pass the test build Products/Debug directory}"
TAILCAT_API_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/tailcat-api.XXXXXX")"
trap 'rm -rf "$TAILCAT_API_TEMP"' EXIT
args=(-swift-version 6 -strict-concurrency=complete -target arm64-apple-macos14.0 -module-cache-path "$TAILCAT_API_TEMP/cache" -I "$TAILCAT_API_PRODUCTS" -F "$TAILCAT_API_PRODUCTS" -typecheck)
xcrun swiftc "${args[@]}" "$TAILCAT_API_ROOT/Tests/Compiler/MessagingConsumer.swift"
printf 'Normal-import actor-isolated consumer compiled\n'
for fixture in MessagingWrongInput MessagingUnencoded MessagingNonSendable MessagingUnaryDuplex MessagingCallDuplex; do
  if xcrun swiftc "${args[@]}" "$TAILCAT_API_ROOT/Tests/Compiler/$fixture.swift" > "$TAILCAT_API_TEMP/$fixture.log" 2>&1; then
    printf 'ERROR: negative fixture unexpectedly compiled: %s\n' "$fixture" >&2
    exit 1
  fi
  if ! grep -q 'error:' "$TAILCAT_API_TEMP/$fixture.log"; then
    cat "$TAILCAT_API_TEMP/$fixture.log"
    exit 1
  fi
  printf 'Rejected expected negative: %s\n' "$fixture"
  cat "$TAILCAT_API_TEMP/$fixture.log"
done
