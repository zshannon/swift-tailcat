#!/usr/bin/env bash
set -euo pipefail
# Owned maintainer validation uses the ignored binary fixture.
export TAILCAT_LOCAL_ARTIFACT=1
TAILCAT_CONSUMER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAILCAT_CONSUMER_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/swift-tailcat-consumer.XXXXXX")"
trap 'rm -rf "$TAILCAT_CONSUMER_TEMP"' EXIT
# The updater validates regenerated tracked source before creating its bot commit.
# Default callers continue consuming the committed checkout.
if [[ "${1:-}" != "--working-tree-snapshot" ]] && git -C "$TAILCAT_CONSUMER_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  git clone --quiet --no-local "$TAILCAT_CONSUMER_ROOT" "$TAILCAT_CONSUMER_TEMP/dependency"
else
# For an explicit working-tree snapshot, or before the initial commit, copy only
# tracked deliverables; untracked files, Git metadata and build outputs stay out.
python3 - "$TAILCAT_CONSUMER_ROOT" "$TAILCAT_CONSUMER_TEMP/dependency" <<'PY'
import pathlib, shutil, subprocess, sys
root, destination = map(pathlib.Path, sys.argv[1:])
for raw in subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0"):
    if not raw: continue
    path = pathlib.Path(raw.decode())
    target = destination / path
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / path, target)
assert (destination / "Package.swift").is_file(), "Stage the package before verifying the tracked snapshot"
PY
fi
# Tests use the ignored local build as their fixture; it is never added to Git.
mkdir -p "$TAILCAT_CONSUMER_TEMP/dependency/Artifacts"
cp "$TAILCAT_CONSUMER_ROOT/Artifacts/TailcatCore.xcframework.zip" "$TAILCAT_CONSUMER_TEMP/dependency/Artifacts/"
mkdir -p "$TAILCAT_CONSUMER_TEMP/consumer/Sources/Check" "$TAILCAT_CONSUMER_TEMP/home"
for tool in go gobind gomobile; do
  if PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v "$tool" >/dev/null; then
    printf 'Consumer PATH unexpectedly contains %s\n' "$tool" >&2
    exit 1
  fi
done
printf 'Consumer PATH has no Go, gobind or gomobile\n'
cat > "$TAILCAT_CONSUMER_TEMP/consumer/Package.swift" <<'SWIFT'
// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "FreshConsumer", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../dependency")],
    targets: [.executableTarget(name: "Check", dependencies: [.product(name: "Tailcat", package: "dependency")])],
    swiftLanguageModes: [.v6])
SWIFT
cat > "$TAILCAT_CONSUMER_TEMP/consumer/Sources/Check/main.swift" <<'SWIFT'
import Foundation
import Tailcat
enum SignedReceipt: Request {
    typealias Input = Data
    typealias Output = Bool
    static let event = "consumer.signed-receipt"
}
actor ReplyBytes {
    var data = Data([84,67,65,84,1,4,0,0,0,4,116,114,117,101,84,67,65,84,1,5,0,0,0,0])
    func read(_ maximum: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        let result = Data(data.prefix(min(maximum, 3)))
        data.removeFirst(result.count)
        return result
    }
}
@main struct Check {
    @Dependency(\.tailcat) var tailcat

    func checkNative() async throws {
        try await tailcat.withSession { runtime in
            var identity = try await runtime.generateIdentity()
            identity.connectionInfo.regionID = 1
            let address = try await runtime.address(from: identity.connectionInfo)
            let restored = try await runtime.connectionInfo(for: address)
            precondition(restored.publicKey == identity.connectionInfo.publicKey)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = try await runtime.makeCache(storage: Tailcat.Cache.FileStorage(directory: directory))
            let url = URL(string: "https://consumer.invalid/map")!
            try await cache.store(data: Data("offline".utf8), etag: "opaque", storedAt: Date(timeIntervalSince1970: 0), url: url)
            let entry = try await cache.entry(for: url)
            precondition(entry.data == Data("offline".utf8) && entry.etag == "opaque" && entry.storedAt == 0)
            let readme = try await runtime.upstreamREADME()
            precondition(readme.contains("Tailscale without Tailscale, by Tailscale"))
        }
    }

    static func main() async throws {
        try await withDependencies {
            $0.tailcat = .liveValue
        } operation: {
            try await Self().checkNative()
        }
        let dependency = Tailcat(makeSession: { _ in
            Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
                Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
                    let reply = ReplyBytes()
                    return Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {},
                        read: { await reply.read($0) }, writeSome: { min($0.count, 3) })
                })
            })
        })
        try await withDependencies {
            $0.tailcat = dependency
        } operation: {
            try await Self().checkRequests()
        }
        print("Fresh Swift-only consumer passed injected live identity/address, disk cache, offline README and retained typed requests")
    }

    func checkRequests() async throws {
        let peer = try await tailcat.connect(address: .init(rawValue: "fixture"))
        do {
            for count in [1, 65537] {
                let accepted = try await peer.call(SignedReceipt.self, input: Data(repeating: 255, count: count))
                precondition(accepted)
            }
            try await peer.close()
        } catch {
            peer.requestShutdown()
            try? await peer.close()
            throw error
        }
    }
}
SWIFT
cd "$TAILCAT_CONSUMER_TEMP/consumer"
env PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$TAILCAT_CONSUMER_TEMP/home" \
  CLANG_MODULE_CACHE_PATH="$TAILCAT_CONSUMER_TEMP/clang-cache" \
  swift run --disable-sandbox --jobs 2 \
  --cache-path "$TAILCAT_CONSUMER_TEMP/cache" --config-path "$TAILCAT_CONSUMER_TEMP/config" \
  --security-path "$TAILCAT_CONSUMER_TEMP/security" --scratch-path "$TAILCAT_CONSUMER_TEMP/build" Check
