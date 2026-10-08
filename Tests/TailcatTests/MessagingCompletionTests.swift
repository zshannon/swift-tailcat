import Foundation
@testable import Tailcat
import Testing

private enum CompletedCount: Request {
    static let event = "completion.count"
    typealias Inbound = Int
    typealias Yield = Int
}

private enum CompletedReply: Request {
    static let event = "completion.reply"
    typealias Output = Int
    typealias Yield = Int
}

@Suite(.timeLimit(.minutes(1))) struct MessagingCompletionTests {
    @Test func consumingVoidOutputStreamClosesRetainedFlowAndReleasesCapacity() async throws {
        let closes = EventCounter()
        let frames: [MessageFrame] = (1...3).map { .init(kind: .data, payload: Data(String($0).utf8)) }
            + [.init(kind: .output), .init(kind: .end)]
        let connection = try await completionConnection(closes: closes, frames: frames)
        let first = try await connection.open(CompletedCount.self)
        try await first.send(1)
        try await first.send(2)
        try await first.finishSending()
        var values: [Int] = []
        for try await value in first.incoming { values.append(value) }
        #expect(values == [1, 2, 3])
        #expect(closes.count == 1)

        let next = try await connection.open(CompletedCount.self)
        try await next.finishSending()
        for try await _ in next.incoming {}
        #expect(closes.count == 2)
        withExtendedLifetime((first, next)) {}
        try await connection.close()
        #expect(closes.count == 2)
    }

    @Test(arguments: [false, true]) func automaticClosePreservesBufferedRepliesAndFinalOutput(resultFirst: Bool) async throws {
        let closes = EventCounter()
        let frames: [MessageFrame] = [
            .init(kind: .data, payload: Data("1".utf8)),
            .init(kind: .data, payload: Data("2".utf8)),
            .init(kind: .output, payload: Data("42".utf8)),
            .init(kind: .end)
        ]
        let connection = try await completionConnection(closes: closes, frames: frames)
        let stream = try await connection.open(CompletedReply.self)
        try await stream.finishSending()
        if resultFirst { #expect(try await stream.result() == 42) }
        var values: [Int] = []
        for try await value in stream.incoming { values.append(value) }
        if !resultFirst { #expect(try await stream.result() == 42) }
        #expect(values == [1, 2])
        #expect(closes.count == 1)
        // Reset remains safe after automatic completion, without closing twice.
        await stream.resetAndWait()
        #expect(closes.count == 1)
        try await connection.close()
    }

    @Test func completionWaitsForActualCleanupToFinish() async throws {
        let entered = FoundationSignal(), release = FoundationSignal(), returned = EventCounter()
        let response = try MessageFrame(kind: .output).encoded(limit: 1024)
            + MessageFrame(kind: .end).encoded(limit: 1024)
        let dependency = Tailcat(makeSession: { _ in
            Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
                Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
                    let bytes = TestWireBytes(response)
                    return Tailcat.TCPConnection(abort: {}, close: {
                        entered.signal(); await release.wait()
                    }, closeWrite: {}, read: { bytes.read($0) }, writeSome: { $0.count })
                })
            })
        })
        let connection = try await dependency.connect(address: .init(rawValue: "peer"))
        let stream = try await connection.open(CompletedCount.self)
        let receiving = Task {
            for try await _ in stream.incoming {}
            returned.increment()
        }
        await entered.wait()
        #expect(returned.count == 0)
        release.signal()
        try await receiving.value
        #expect(returned.count == 1)
        try await connection.close()
    }

    @Test func completedErrorRepliesCloseRetainedFlowsAndReleaseCapacity() async throws {
        let closes = EventCounter()
        let error = MessageFailure.remote(code: "denied", message: "Denied")
        let payload = try JSONEncoder().encode(MessageRemoteError(code: "denied", message: "Denied"))
        let connection = try await completionConnection(closes: closes,
            frames: [.init(kind: .error, payload: payload), .init(kind: .end)])
        let first = try await connection.open(CompletedCount.self)
        await #expect(throws: error) { try await first.result() }
        #expect(closes.count == 1)
        let next = try await connection.open(CompletedCount.self)
        await #expect(throws: error) { for try await _ in next.incoming {} }
        #expect(closes.count == 2)
        withExtendedLifetime((first, next)) {}
        try await connection.close()
    }
}

private func completionConnection(closes: EventCounter, frames: [MessageFrame]) async throws -> Tailcat.Connection {
    let payload = try frames.reduce(into: Data()) { result, frame in result.append(try frame.encoded(limit: 1024)) }
    let dependency = Tailcat(makeSession: { _ in
        Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
            Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
                let bytes = TestWireBytes(payload, chunk: 1)
                return Tailcat.TCPConnection(abort: {}, close: { closes.increment() }, closeWrite: {},
                    read: { bytes.read($0) }, writeSome: { $0.count })
            })
        })
    })
    return try await dependency.connect(address: .init(rawValue: "peer"), configuration: .init(maxConcurrentRequests: 1))
}
