import CryptoKit
import Foundation
import Tailcat

enum DemoError: Error {
    case rejectedSignature
}

struct SignedDiff: Codable, Sendable {
    let payload: Data
    let signature: Data
}

enum SubmitDiff: Request {
    typealias Input = SignedDiff
    typealias Output = Bool
    static let event = "example.signed-diff"
}

@main @MainActor struct TypedRequestsDemo {
    @Dependency(\.tailcat) var tailcat

    static func main() async throws {
        try await Self().run()
    }

    func run() async throws {
        // One-process signature demo: this creates its own key; no roster is authenticated.
        // It does not apply or persist document changes.
        let signingKey = Curve25519.Signing.PrivateKey()
        let verificationKey = signingKey.publicKey
        let listener = try await tailcat.listen(port: 0) {
            Handle(SubmitDiff.self) { envelope in
                // Verify only the payload signature against the locally captured key.
                // Production apps also authenticate the roster, authorize and apply the change.
                verificationKey.isValidSignature(envelope.signature, for: envelope.payload)
            }
        }
        var connection: Tailcat.Connection?
        do {
            let peer = try await tailcat.connect(address: listener.address, port: listener.port)
            connection = peer
            // Retain the same peer owner; each call uses an independent TCP flow.
            for count in [1, 4 * 1024 * 1024] {
                try Task.checkCancellation()
                let payload = Data(repeating: 42, count: count)
                let envelope = SignedDiff(payload: payload, signature: try signingKey.signature(for: payload))
                let accepted = try await peer.call(SubmitDiff.self, input: envelope)
                guard accepted else { throw DemoError.rejectedSignature }
                print("Verified signed payload: \(count) bytes")
            }
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
