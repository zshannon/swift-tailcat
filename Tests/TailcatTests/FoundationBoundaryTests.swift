import Foundation
@testable import Tailcat
import Testing

@Suite struct FoundationBoundaryTests {
    @Test func fakeAndClosedKeyLoadingNeverFetchesOrReadsFiles() async throws {
        let calls = EventCounter()
        let session = Tailcat.Session(abort: {}, close: {})
        await #expect(throws: Tailcat.Failure.unimplemented("Session.loadSSHAuthorizedKeys")) {
            try await session.loadSSHAuthorizedKeys(sources: [.github("example")], fetch: { _ in
                calls.increment(); return Data()
            })
        }
        await #expect(throws: Tailcat.Failure.unimplemented("Session.loadSSHAuthorizedKeys")) {
            try await session.loadSSHAuthorizedKeys(sources: [.file(URL(fileURLWithPath: "/nonexistent-tailcat-key"))])
        }
        try await session.close()
        await #expect(throws: Tailcat.Failure.closed) {
            try await session.loadSSHAuthorizedKeys(sources: [.github("example")], fetch: { _ in
                calls.increment(); return Data()
            })
        }
        #expect(calls.count == 0)
    }

    @Test func pendingAcceptCancellationInterruptsOnlyListener() async throws {
        let entered = FoundationSignal()
        let interrupted = FoundationSignal()
        let listener = try Tailcat.TCPListener(abort: { interrupted.signal() }, accept: {
            entered.signal(); await interrupted.wait(); throw CancellationError()
        }, close: {})
        let task = Task { try await listener.accept() }
        await entered.wait()
        task.cancel()
        #expect(interrupted.isSignaled)
        interrupted.signal() // Keeps the regression finite on the old implementation.
        await #expect(throws: CancellationError.self) { try await task.value }
        try await listener.close()
    }

    @Test func closeCallbackCannotJoinAncestor() async throws {
        let outcome = FoundationSignal()
        let parent = Ownership(abort: {}, close: {})
        let child = Ownership(abort: {}, close: {
            parent.requestShutdown()
            await #expect(throws: Tailcat.Failure.ownershipConflict) { try await parent.close() }
            outcome.signal()
        })
        try parent.attach(child)
        parent.requestShutdown()
        for _ in 0..<100 where !outcome.isSignaled { try await Task.sleep(for: .milliseconds(2)) }
        #expect(outcome.isSignaled)
        if outcome.isSignaled { try await parent.close() }
    }

    @Test func closeCallbackCannotJoinItself() async throws {
        let reference = CloseReference()
        let done = FoundationSignal()
        let owner = Ownership(abort: {}, close: {
            await #expect(throws: Tailcat.Failure.ownershipConflict) { try await reference.close() }
            done.signal()
        })
        await reference.set(owner)
        owner.requestShutdown()
        for _ in 0..<100 where !done.isSignaled { try await Task.sleep(for: .milliseconds(2)) }
        #expect(done.isSignaled)
        if done.isSignaled { try await owner.close() }
    }

    @Test func diagnosticCallbackCanJoinCompletedClose() async throws {
        let joined = FoundationSignal()
        let reference = CloseReference()
        let owner = Ownership(abort: {}, close: { throw Tailcat.Failure.operationFailed("cleanup") })
        await reference.set(owner)
        try owner.claimRoot(onDiagnostic: { _ in
            let semaphore = DispatchSemaphore(value: 0)
            Task { try? await reference.close(); semaphore.signal() }
            #expect(semaphore.wait(timeout: .now() + 2) == .success)
            joined.signal()
        })
        try? await owner.close()
        await joined.wait()
    }

    @Test func completeWriteSendsEveryByteWithoutReplay() async throws {
        let bytes = LockedBytes()
        let connection = Tailcat.TCPConnection(abort: {}, close: {}, writeSome: { data in
            let count = min(2, data.count); bytes.append(data.prefix(count)); return count
        })
        _ = try await connection.write(Data("abcdefg".utf8))
        #expect(bytes.data == Data("abcdefg".utf8))
        try await connection.close()
    }

    @Test func noProgressWriteFailsAndEmptyWriteDoesNotInvokeProvider() async throws {
        let calls = EventCounter()
        let connection = Tailcat.TCPConnection(abort: {}, close: {}, writeSome: { _ in calls.increment(); return 0 })
        _ = try await connection.write(Data())
        #expect(try await connection.writeSome(Data()) == 0)
        #expect(calls.count == 0)
        await #expect(throws: (any Error).self) { try await connection.write(Data([1])) }
        try await connection.close()
        await #expect(throws: Tailcat.Failure.closed) { try await connection.write(Data()) }
    }

    @Test func partialWriteFailureAccumulatesCountAndPreservesCause() async throws {
        let calls = EventCounter()
        let connection = Tailcat.TCPConnection(abort: {}, close: {}, writeSome: { data in
            calls.increment()
            if calls.count == 1 { return 2 }
            throw Tailcat.TCPConnection.WriteFailure(bytesWritten: 1, cause: Tailcat.Failure.operationFailed("genuine"))
        })
        do {
            try await connection.write(Data("abcdef".utf8))
            Issue.record("write unexpectedly succeeded")
        } catch let error as Tailcat.TCPConnection.WriteFailure {
            #expect(error.bytesWritten == 3)
            #expect(error.cause as? Tailcat.Failure == .operationFailed("genuine"))
        }
        #expect(calls.count == 2)
        try await connection.close()
    }

    @Test(arguments: [false, true])
    func completeWriteLaterZeroProgressErrorPreservesCause(_ cancel: Bool) async throws {
        let calls = EventCounter()
        let consumed = LockedBytes()
        let connection = Tailcat.TCPConnection(abort: {}, close: {}, writeSome: { data in
            calls.increment()
            if calls.count == 1 { consumed.append(data.prefix(2)); return 2 }
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            throw Tailcat.Failure.operationFailed("genuine second-write failure")
        })
        let task = Task {
            do {
                try await connection.write(Data("abcdef".utf8))
                Issue.record("write unexpectedly succeeded")
            } catch let error as Tailcat.TCPConnection.WriteFailure {
                #expect(error.bytesWritten == 2)
                #expect(error.cause as? Tailcat.Failure == .operationFailed("genuine second-write failure"))
            }
        }
        try await task.value
        #expect(calls.count == 2)
        #expect(consumed.data == Data("ab".utf8))
        try await connection.close()
    }

    @Test func canceledReadCooperatesWithoutAbortingFlow() async throws {
        let aborts = EventCounter()
        let entered = FoundationSignal()
        let reads = EventCounter()
        let connection = Tailcat.TCPConnection(abort: { aborts.increment() }, close: {}, read: { _ in
            reads.increment()
            if reads.count == 1 { entered.signal(); try await Task.sleep(for: .seconds(30)) }
            return Data([1])
        }, writeSome: { $0.count })
        let task = Task { try await connection.read() }
        await entered.wait()
        await #expect(throws: Tailcat.Failure.ownershipConflict) { try await connection.read() }
        try await connection.write(Data([2]))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(aborts.count == 0)
        #expect(try await connection.read() == Data([1]))
        try await connection.close()
    }

    @Test func pendingUDPAcceptAndPreAdmissionCancellation() async throws {
        let entered = FoundationSignal()
        let interrupted = FoundationSignal()
        let aborts = EventCounter()
        let listener = try Tailcat.UDPListener(abort: { aborts.increment(); interrupted.signal() }, accept: {
            entered.signal(); await interrupted.wait(); throw CancellationError()
        }, close: {})
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await listener.accept()
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(aborts.count == 0)
        let task = Task { try await listener.accept() }
        await entered.wait()
        task.cancel()
        #expect(interrupted.isSignaled)
        await #expect(throws: CancellationError.self) { try await task.value }
        try await listener.close()
        #expect(aborts.count == 1)
    }

    @Test func overlappingDirectionsConflictButReadAndWriteCoexist() async throws {
        let entered = FoundationSignal()
        let release = FoundationSignal()
        let connection = Tailcat.TCPConnection(abort: {}, close: {}, read: { _ in Data([9]) }, writeSome: { data in
            entered.signal(); await release.wait(); return data.count
        })
        let first = Task { try await connection.write(Data([1])) }
        await entered.wait()
        // Only release on a bounded failure escape, never as proof of admission.
        let escape = Task {
            do { try await Task.sleep(for: .seconds(5)); release.signal() }
            catch {}
        }
        defer { escape.cancel(); release.signal() }
        #expect(try await connection.read() == Data([9]))
        await #expect(throws: Tailcat.Failure.ownershipConflict) {
            try await connection.writeSome(Data([2]))
        }
        release.signal()
        _ = try await first.value
        try await connection.close()
    }
}

// Mutable bytes are protected by the lock; callbacks never run under it.
private final class LockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    var data: Data { lock.withLock { value } }
    func append(_ data: Data) { lock.withLock { value.append(data) } }
}

private actor CloseReference {
    private var owner: Ownership?
    func close() async throws { try await owner?.close() }
    func set(_ owner: Ownership) { self.owner = owner }
}
