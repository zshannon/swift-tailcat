import Dependencies
import Foundation
import Tailcat

enum SignedEnvelope: Request {
    typealias Input = Data
    typealias Output = Bool
    static let event = "quantum.signed-envelope"
}
enum SyncMessages: Request {
    typealias Inbound = Data
    typealias Input = String
    typealias Output = Int
    typealias Yield = Data
    static let event = "sync"
}
enum Health: Request { static let event = "health" }

@MainActor final class Document {
    @Dependency(\.tailcat) var tailcat
    var name = "document"
    func listen() async throws -> Tailcat.Listener {
        try await tailcat.listen(port: 7000) {
            let snapshot = name
            Handle(SignedEnvelope.self) { data in !data.isEmpty && !snapshot.isEmpty }
            Handle(SyncMessages.self) { _, stream in
                var count = 0
                for try await value in stream.incoming {
                    count += 1
                    try await stream.yield(value)
                }
                try await stream.finishSending()
                return count
            }
            Handle(Health.self) { _ in }
        }
    }
    func send(address: Tailcat.Address, bytes: Data) async throws {
        let connection = try await tailcat.connect(address: address, port: 7000)
        _ = try await connection.call(SignedEnvelope.self, input: bytes)
        try await connection.call(Health.self)
        let stream = try await connection.open(SyncMessages.self, input: name)
        try await stream.send(bytes)
        try await stream.finishSending()
        for try await _ in stream.incoming {}
        _ = try await stream.result()
        await stream.resetAndWait()
        try await connection.close()
    }
}
