# Swift Tailcat

`Tailcat` is a Swift 6 library for iOS 16+ and macOS 13+, backed by the official [Tailcat Go library](https://github.com/tailscale/tailcat/tree/b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f). It provides encrypted userspace TCP/UDP, SSH/SFTP, forwarding, file services and typed peer requests. No Tailscale account or system VPN is required.

## Add the package and run a request

The receiving app listens and handles requests; the calling app connects and sends them. Both apps share the same `Request` declaration. This example runs both roles together. Separate apps exchange the listener's address through their existing authenticated presence service.

Use the `main` branch. Consumers need Swift tools 6.4 and Xcode, without Go or private asset credentials.

Create `Package.swift`:

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Demo",
    platforms: [.iOS(.v16), .macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/zshannon/swift-tailcat.git", branch: "main")
    ],
    targets: [
        .executableTarget(name: "Demo", dependencies: [
            .product(name: "Tailcat", package: "swift-tailcat")
        ])
    ],
    swiftLanguageModes: [.v6]
)
```

Create `Sources/Demo/main.swift`:

```swift
import Tailcat

// Request inherits Sendable. String and Int conform to Codable & Sendable.
enum Greeting: Request {
    // Both peers must match event and version.
    static let event = "example.greeting"

    // Defaults to 1; uncomment to declare it explicitly.
    // static let version = 1

    // Passed once to the handler as name. Defaults to Void; String? allows nil.
    typealias Input = String

    // The handler's return value, awaited by call(). Defaults to Void.
    typealias Output = String
}

// Input and Output default to Void; this request streams values in both directions.
enum Count: Request {
    static let event = "example.count"

    // Each number sent by the caller and read from the handler's stream.incoming.
    typealias Inbound = Int

    // Each number yielded by the handler and read from the caller's stream.incoming.
    typealias Yield = Int
}

@main @MainActor struct Demo {
    @Dependency(\.tailcat) var tailcat

    static func main() async throws { try await Self().run() }

    func run() async throws {
        let listener = try await tailcat.listen {
            Handle(Greeting.self) { name in "Hello, \(name)!" }

            Handle(Count.self) { _, stream in
                var sum = 0
                for try await number in stream.incoming { sum += number }

                // The input stream is complete; now emit 1 through the sum.
                if sum > 0 {
                    for number in 1...sum { try await stream.yield(number) }
                }
            }
        }
        let peer = try await tailcat.connect(address: listener.address)

        let greeting = try await peer.call(Greeting.self, input: "Sam")
        print(greeting)

        let stream = try await peer.open(Count.self)
        try await stream.send(1)
        try await stream.send(2)

        // Ends the handler's input sequence so it can finish summing.
        try await stream.finishSending()

        // On the caller, incoming receives the handler's Yield values.
        // This loop ends when the handler's response is complete.
        for try await number in stream.incoming { print(number) }
    }
}

```

Run `swift run Demo` on macOS. It prints `Hello, Sam!`, then `1`, `2`, and `3`. Count reads the complete input stream `[1, 2]`, sums it to `3`, and yields each number from `1` through `3`. In an app, retain the listener while serving and reuse the peer for subsequent requests; [Streaming and lifetime](#streaming-and-lifetime) covers resource cleanup.

## Signed document requests

Send an already signed diff as `Data` and receive a `Bool` acceptance result. Your app supplies the handler that verifies the signature, checks document access, and applies the diff.

```swift
import Foundation
import Tailcat

enum SubmitDiff: Request {
    static let event = "app.signed-diff"

    // Your app's encoded, signed envelope.
    typealias Input = Data

    // Whether the receiving app accepted the diff.
    typealias Output = Bool
}

struct DocumentRequests {
    @Dependency(\.tailcat) var tailcat

    func submitSignedEnvelope(
        envelope: Data,
        verifyAuthorizeAndApply: @escaping @Sendable (Data) async throws -> Bool
    ) async throws -> Bool {
        let listener = try await tailcat.listen {
            Handle(SubmitDiff.self) { receivedEnvelope in
                try await verifyAuthorizeAndApply(receivedEnvelope)
            }
        }
        let peer = try await tailcat.connect(address: listener.address)
        return try await peer.call(SubmitDiff.self, input: envelope)
    }
}
```

This example runs both peers locally. In an app, retain the receiving listener and reuse the caller's connection. `false` is an application rejection; thrown handler errors become remote failures. Use app-level deduplication if you retry a failed or cancelled call.

The [standalone signed-diff demo](Examples/TypedRequests.swift) can replace `Sources/Demo/main.swift` above. It uses `@Dependency(\.tailcat)`, creates a local signing key and captures its public key, then verifies 1-byte and 4 MiB payload signatures through a retained peer. It does **not** authenticate a document roster or apply/persist changes. A full 4 MiB payload plus its signature fits the default 8 MiB encoded-frame limit, including JSON base64 overhead. It uses the same default networking. `Tailcat` re-exports Dependencies, so the single package product and `import Tailcat` provide `@Dependency(\.tailcat)` and test overrides. Apps that already use Dependencies can retain their existing dependency/import. [Dependency environments](Docs/Design.md#dependency-environments) explain live, test and preview selection; [advanced relay configuration](Docs/Design.md#configuration-identity-and-admission) is optional.

## Streaming and lifetime

[Typed requests](Docs/Messaging.md) teaches request lanes, a complete concurrent duplex example, errors and cleanup. `call` is for unary requests; streaming uses `open`, `send`, `incoming`, `finishSending` and a separate `result`.

A typed `Tailcat.Listener` owns its Session, Server, raw listener and active handlers. A typed `Tailcat.Connection` owns its Session and outgoing Client. Cancellation closes the affected typed request and joins its reader/writer work; sibling requests remain usable. Owner `close()` is asynchronous, joined and idempotent. `requestShutdown()` initiates interruption; the owning task must still join `close()`. Handlers and injected providers must cooperate with cancellation. A handler must not await its own listener's close.

Raw TCP/UDP, SSH/SFTP and forwarding are available through `Tailcat.Session`, `Tailcat.Server`, `Tailcat.Client` and their resources. Their ownership and cancellation scopes are explained in [Design](Docs/Design.md). Both application peers must support the typed framing; stock CLI raw streams do not speak it.

## Maintainer verification and releases

Maintainers need macOS with Xcode and its command-line tools, Python 3 and a Go bootstrap tool; the build downloads its pinned Go/mobile inputs. First run `Scripts/build-xcframework.sh` to produce the matching ignored `Artifacts/TailcatCore.xcframework.zip` and manifest, then run the checks below. Set `TAILCAT_LOCAL_ARTIFACT=1` when invoking SwiftPM against that local build; the environment variable selects an existing artifact and does not build it. Owned validation helpers select local artifact mode themselves:

```sh
python3 -B -m unittest discover -s Scripts/tests -v
python3 -B Scripts/verify-artifact.py
Scripts/check-platforms.sh
Scripts/test-swift.sh
Scripts/test-consumer.sh
Scripts/test-go.sh
```

Build scripts pin Go **1.27.1**, x/mobile **v0.0.0-20260908204917-8b95e45f8d3e**, and Tailcat **v0.7.1-0.20260929145319-b4dc28e8aa89** (commit **b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f**). Swift Dependencies is exactly **1.17.1**. Go/build tools and caches are maintainer inputs; importing the library does not run Go.

All five Apple architectures compile/link. Runtime validation covers macOS arm64 and owned loopback services. Device/simulator runtime, macOS Intel runtime and internet NAT traversal remain unverified. There is no QUIC, instant cold-start guarantee, native path-change stream or promised continuous iOS background execution. Local shell/PTY execution is macOS only. See [coverage](Docs/Coverage.md) and [CLI interoperability](Docs/CLIInteroperability.md).

[Releases](Docs/Releases.md) require explicit local preparation and manual publication, with the binary separate from source. The [weekly/manual updater](.github/workflows/update-upstream.yml) freezes one official SHA, skips unchanged/already proposed revisions, rebuilds and validates the bridge, and maintains one open source PR with the built-in workflow token. Later upstream revisions update that verified bot PR instead of opening another. Its tests use the rebuilt local artifact; normal SwiftPM consumers receive the updated bridge through a separately reviewed release. See [weekly update behavior and prerequisites](Docs/Releases.md#weekly-official-upstream-updates). It performs no automatic merge/release or binary upload and uses no persistent Actions caches or Actions artifact uploads.

## License and provenance

The wrapper is [BSD-3-Clause](LICENSE). Official Tailcat is imported at the pinned revision. The unmodified official internal performance implementation and tests retain [provenance](Bridge/internal/upstreamperf/PROVENANCE.md) and licenses; the build's copy verifier checks `perf.go`. The binary ZIP contains the license and [third-party notices](THIRD_PARTY_NOTICES.md); the source ZIP contains those plus the [dependency inventory](Docs/DependencyInventory.json). No HerdrTailcat source or binaries are included. The preserved [official README](Docs/UpstreamREADME.md) has links relative to the upstream repository layout; use the pinned official tree linked above for those assets.
