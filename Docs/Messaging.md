# Typed requests

Start with the [README round trip](../README.md#add-the-package-and-run-a-request): the receiving app retains a `Tailcat.Listener`, and the calling app retains a `Tailcat.Connection` with that listener's address and port. Share request declarations between the apps. `Request` and `Handle` are global declarations available through ordinary `import Tailcat`.

## Choose the request lanes

Each request has an initial input, a final output, and optional ongoing messages:

| Declaration | Direction | Default |
|---|---|---|
| `Input` | Caller supplies one initial value to the handler | `Void` |
| `Output` | Handler returns one terminal value to the caller | `Void` |
| `Inbound` | Caller sends ongoing values to the handler | `Never` |
| `Yield` | Handler sends ongoing values to the caller | `Never` |
| `version` | Shared event version | `1` |

All lane types must be Sendable; concrete nonempty lanes require Codable. `Void` represents an empty initial/final value; `Never` removes an ongoing lane. Use `connection.call` only when both ongoing lanes are absent. Omit `input:` when Input is Void. `Handle` accepts a unary closure for unary requests, or an `(input, stream)` closure for any shape.

Events contain 1–128 printable non-space ASCII bytes, and versions are 1–65535. Duplicate event/version pairs fail before acquiring a Session. Registration captures the current Dependencies environment. The listener builder runs in caller isolation, so an actor can snapshot state before its Sendable handler escapes. See [dependency environments](Design.md#dependency-environments) for live/test/preview behavior.

## Send and receive concurrently

For streaming, `open` returns `Tailcat.RequestStream<R.Yield, R.Inbound, R.Output>` on the caller. Its `send` sends Inbound values; `incoming` receives Yield values. Caller `finishSending` sends END and half-closes the sending direction. Read the final Output separately with `result()`.

The handler receives `Tailcat.Stream<R.Inbound, R.Yield>`. It consumes `incoming`, sends with `yield`, and returns Output. Handler `finishSending` prevents further yields; its returned Output still completes the response. Completion revokes escaped stream writes and interrupts an unread inbound lane.

A protocol that emits messages while consuming incoming messages needs concurrent send/receive. Unconsumed yields can fill the bounded inbox and stop the reader before it reaches the final result. Small buffered yields may reach the result before consumption, but do not rely on that. Use one lifetime iterator for each `incoming` sequence and one lifetime `result()` consumer.

This complete executable uses the README's Package.swift and `Sources/Demo/main.swift` layout, with the same single Tailcat import, instance dependency and default networking. The caller starts one receiver task before sending and joins it on every exit; completed flows clean up automatically. The handler doubles each incoming number and returns a separate count:

```swift
import Tailcat

enum DoubleNumbers: Request {
    typealias Inbound = Int
    typealias Output = Int
    typealias Yield = Int
    static let event = "example.double-numbers"
}

func sendNumbers(connection: Tailcat.Connection) async throws -> Int {
    let stream = try await connection.open(DoubleNumbers.self)
    let receiver = Task {
        for try await doubled in stream.incoming {
            print("Doubled: \(doubled)")
        }
    }
    do {
        for number in 1...10 {
            try await stream.send(number)
        }
        try await stream.finishSending()
        let count = try await stream.result()
        try await receiver.value
        return count
    } catch {
        receiver.cancel()
        await stream.resetAndWait()
        _ = try? await receiver.value
        throw error
    }
}

@main @MainActor struct DuplexDemo {
    @Dependency(\.tailcat) var tailcat

    static func main() async throws { try await Self().run() }

    func run() async throws {
        let listener = try await tailcat.listen(port: 0) {
            Handle(DoubleNumbers.self) { _, stream in
                var count = 0
                for try await number in stream.incoming {
                    try await stream.yield(number * 2)
                    count += 1
                }
                try await stream.finishSending()
                return count
            }
        }
        var connection: Tailcat.Connection?
        do {
            let peer = try await tailcat.connect(address: listener.address, port: listener.port)
            connection = peer
            print("Final count: \(try await sendNumbers(connection: peer))")
            try await peer.close()
            try await listener.close()
        } catch {
            connection?.requestShutdown()
            listener.requestShutdown()
            try? await connection?.close()
            try? await listener.close()
            throw error
        }
    }
}
```

Completed requests close their TCP flow and release their request slot automatically. Finishing the caller's `incoming` loop or awaiting `result()` joins that cleanup. Buffered replies and the final Output remain available after the flow closes. Use async, nonthrowing `resetAndWait()` to abandon an unfinished stream; it interrupts and joins that flow's reader/writer work. Join any child tasks your app starts too, as above.

## Retain owners and close them

A typed `Tailcat.Listener` is the receiving owner: it owns its Session, Server, raw TCP listener and handler tasks. Closing it interrupts active handlers and joins the whole graph. A typed `Tailcat.Connection` is the outgoing owner: it owns one Session and lazy Client. Reuse it until the remote address or configuration changes. Each request opens a separate TCP flow; there is no multiplexed carrier, implicit connection cache or reconnect policy.

Both typed roots default to port 1. Listener port 0 selects an unused Tailcat tunnel port, exposed as `listener.port`. Connect to the actual same port; the address does not include it. The typed listener's default server configuration sets `allowedProxies: []` to deny proxy destinations. A supplied server configuration replaces that default rather than merging with it: a custom server with only `derpMapURL` set uses raw Server defaults. Include `allowedProxies: []` explicitly when supplying a custom server configuration to retain the deny list. A supplied policy replaces list decisions, and its default callbacks permit traffic. Tunnel identity does not authorize document membership. The stream context exposes connection addresses, event and version, not an application-authenticated sender identity. App signing keys and trusted document rosters are separate from Tailcat node/admission keys and SSH host-key pinning/client authentication. Default server configuration creates a fresh identity; stable identity persistence is optional [advanced configuration](Design.md#configuration-identity-and-admission).

`connect` creates a local owner; it does not establish remote connectivity. Listener startup may fetch/select relay information and await work. `statuses` provides bounded local ready/closing/closed observations, and ready is not proof of Internet or relay reachability. `ping` and `discoPing` expose existing Client observations. There is no native path-change stream, QUIC, instant cold-start or continuous iOS background guarantee.

Owner `close()` is asynchronous, joined and idempotent. `requestShutdown()` initiates interruption; the owning task must still await close. Owners invalidate descendants and join admitted work. Handlers and injected providers must cooperate with cancellation. A handler must not await its own listener's close: that fails with `Tailcat.Failure.ownershipConflict`. It may request shutdown and let a separate owning task join.

These typed rules differ from raw `Tailcat.TCPListener`/`Tailcat.UDPListener`: closing a raw listener stops accepts but preserves already accepted children owned by the Server. Raw read/write cancellation applies directional deadlines, while SSH/SFTP cancellation can close the shared SSH subtree. See [raw ownership and cancellation](Design.md#ownership-and-cancellation).

## Errors, capacity and cancellation

Application rejection can be an ordinary Output, such as `Bool(false)` for a rejected envelope. A thrown handler error is sanitized to `Tailcat.Messaging.Failure.remote(code: "request_failed", message: "Request could not be completed")`; the application's original error does not cross the wire. The bounded error response is best effort: transport failure, cancellation, overload or deadline setup failure can instead leave the caller with a local flow/transport failure.

`Tailcat.Messaging.Failure` exposes `capacity`, `closed`, `consumerConflict`, `invalidConfiguration`, `invalidRequest`, `malformedFrame`, `oversizedMessage` and `remote(code:message:)`. These cover typed admission, lifecycle, consumer, configuration and framing failures. Codec errors and transport/bridge `Tailcat.Failure` can propagate separately. `Tailcat.Failure` covers invalid input, ownership conflicts, closed resources, unsupported capabilities and upstream/I/O errors.

Connection capacity rejects new requests immediately rather than queuing them. A Listener at its handler limit closes an excess accepted flow. Defaults are 8 MiB per encoded frame, two buffered incoming messages, sixteen pending sends, sixteen concurrent requests per Connection and sixteen accepted handlers per Listener. A slow consumer stalls its own flow. The reader may hold one additional bounded frame while waiting on its inbox; output storage holds at most one encoded message, and only one admitted writer encodes at a time. These are retained encoded-data bounds, not bounds on arbitrary custom Codable allocations, native socket/netstack buffers, or arguments retained by waiting callers.

Cancelling an incoming/result/send wait closes only that typed flow and joins its reader/writer work; siblings can continue using the Client. A partial or uncertain write closes the flow without replay. Cancellation is not always a direct `CancellationError`: `Tailcat.TCPConnection.WriteFailure` can wrap it after write progress. Failure or cancellation does not prove the handler had no side effects. The application decides whether to retry and supplies idempotency where needed.

`Listener.Configuration.ioTimeout` sets an optional absolute socket read/write deadline from acceptance, before parsing, and retains it through response writes. Default nil leaves I/O unbounded, including long-lived duplex flows. It does not time out application handler execution. Unsupported/nonpositive durations fail before allocation; failure to install a deadline closes that flow without an unbounded error reply.

Native resource cleanup executes and joins its actual outcome even when Session shutdown interrupts before or during close. Genuine cleanup failures, including cancellation returned by an injected provider, can propagate from owner close. The expanded lifecycle examples preserve the primary operation error while attempting joined cleanup on failure.

## Signed payloads and compatibility

The [standalone signed-diff demo](../Examples/TypedRequests.swift) creates a local signing key and captures its public key. It verifies payload signatures only; it neither authenticates a document roster nor applies/persists changes. Production signature verification, roster authentication, document authorization and application remain app responsibilities. A full 4 MiB payload plus its signature fits the default frame limit, including JSON base64 overhead.

Both app peers must implement the typed framing. The stock CLI's raw stream does not speak it, and the old EOF/one-byte ACK adapter is incompatible. Maintainers can consult the separate [internal typed wire reference](MessagingWire.md). Owned loopback validation establishes no public relay, device or latency guarantee.
