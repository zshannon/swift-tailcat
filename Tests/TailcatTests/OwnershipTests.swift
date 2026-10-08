import Foundation
@testable import Tailcat
import Testing

@Suite struct OwnershipTests {
    @Test func acquisitionDiagnosticsReachPreconstructedDescendants() async throws {
        let reported = FoundationSignal()
        let reports = EventCounter()
        let session = Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
            Tailcat.Client(abort: {}, close: { throw Tailcat.Failure.operationFailed("preconstructed child") })
        })
        let child = try await session.makeClient(address: .init(rawValue: "owned"))
        let dependency = Tailcat(makeSession: { _ in session })
        let acquired = try await dependency.makeSession(configuration: .init(onDiagnostic: { _ in reports.increment(); reported.signal() }))
        try? await acquired.close()
        withExtendedLifetime(child) {}
        await reported.wait()
        #expect(reports.count == 1)
    }

    @Test func sessionShutdownSynchronouslyInterruptsAdoptedPrimitive() async throws {
        let interrupted = FoundationSignal()
        let session = Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
            Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
                Tailcat.TCPConnection(abort: { interrupted.signal() }, close: {})
            })
        })
        let client = try await session.makeClient(address: .init(rawValue: "owned"))
        let connection = try await client.connectTCP()
        session.requestShutdown()
        #expect(interrupted.isSignaled)
        await #expect(throws: Tailcat.Failure.closed) { try await connection.read() }
        try await session.close()
    }

    @Test func childCleanupFailureIsReportedOnlyOnceAcrossAncestors() async throws {
        let reported = FoundationSignal()
        let reports = EventCounter()
        let dependency = Tailcat(makeSession: { _ in
            Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
                Tailcat.Client(abort: {}, close: { throw Tailcat.Failure.operationFailed("child cleanup") })
            })
        })
        let session = try await dependency.makeSession(configuration: .init(onDiagnostic: { _ in reports.increment(); reported.signal() }))
        let child = try await session.makeClient(address: .init(rawValue: "owned"))
        await #expect(throws: Tailcat.Failure.operationFailed("child cleanup")) { try await session.close() }
        withExtendedLifetime(child) {}
        await reported.wait()
        #expect(reports.count == 1)
    }

    @Test func cancellationBeforeAcquisitionDoesNotCallProvider() async {
        let calls = EventCounter()
        let dependency = Tailcat(makeSession: { _ in
            calls.increment()
            return Tailcat.Session(abort: {}, close: {})
        })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await dependency.makeSession()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls.count == 0)
    }

    @Test func alreadyOwnedProviderReturnIsRejectedWithoutClosingRightfulOwner() async throws {
        let aborts = EventCounter()
        let closes = EventCounter()
        let resource = Tailcat.Session(abort: { aborts.increment() }, close: { closes.increment() })
        let dependency = Tailcat(makeSession: { _ in resource })
        let owner = try await dependency.makeSession()
        await #expect(throws: Tailcat.Failure.ownershipConflict) { try await dependency.makeSession() }
        #expect(aborts.count == 0 && closes.count == 0)
        try await owner.close()
        #expect(aborts.count == 1 && closes.count == 1)
    }

    @Test func canceledLateAcquisitionClosesOnlyItsUnpublishedResource() async throws {
        let entered = FoundationSignal()
        let release = FoundationSignal()
        let closes = EventCounter()
        let dependency = Tailcat(makeSession: { _ in
            entered.signal()
            await release.wait()
            return Tailcat.Session(abort: {}, close: { closes.increment() })
        })
        let task = Task { try await dependency.makeSession() }
        await entered.wait()
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(closes.count == 1)
    }

    @Test func canceledForeignChildReturnPreservesItsOwner() async throws {
        let aborts = EventCounter()
        let entered = FoundationSignal()
        let release = FoundationSignal()
        let child = Tailcat.Client(abort: { aborts.increment() }, close: {})
        let first = Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in child })
        let second = Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
            entered.signal()
            await release.wait()
            return child
        })
        _ = try await first.makeClient(address: .init(rawValue: "owned"))
        let task = Task { try await second.makeClient(address: .init(rawValue: "other")) }
        await entered.wait()
        task.cancel()
        release.signal()
        await #expect(throws: Tailcat.Failure.ownershipConflict) { try await task.value }
        #expect(aborts.count == 0)
        try await first.close()
        try await second.close()
        #expect(aborts.count == 1)
    }

    @Test func shutdownInterruptsStructuredChildBeforeJoiningScope() async throws {
        let entered = FoundationSignal()
        let interrupted = FoundationSignal()
        let finishes = EventCounter()
        let dependency = Tailcat(makeSession: { _ in
            Tailcat.Session(abort: { interrupted.signal() }, close: { finishes.increment() })
        })
        let task = Task {
            try await dependency.withSession { _ in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { entered.signal(); await interrupted.wait() }
                    await group.waitForAll()
                }
                try Task.checkCancellation()
            }
        }
        await entered.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(finishes.count == 1)
    }

    @Test func scopePreservesBodyErrorAndReportsCleanupFailureOnce() async {
        let reported = FoundationSignal()
        let reports = EventCounter()
        let dependency = Tailcat(makeSession: { _ in
            Tailcat.Session(abort: {}, close: { throw Tailcat.Failure.operationFailed("cleanup") })
        })
        await #expect(throws: Tailcat.Failure.operationFailed("body")) {
            try await dependency.withSession(configuration: .init(onDiagnostic: { _ in reports.increment(); reported.signal() })) { _ in
                throw Tailcat.Failure.operationFailed("body")
            }
        }
        await reported.wait()
        #expect(reports.count == 1)
    }

    @Test func childRegistrationPrecedesPublicationAndParentCloseIsShared() async throws {
        let closes = EventCounter()
        let child = Tailcat.Client(abort: {}, close: { closes.increment() })
        let session = Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in child })
        _ = try await session.makeClient(address: .init(rawValue: "owned"))
        await #expect(throws: Tailcat.Failure.ownershipConflict) {
            try await session.makeClient(address: .init(rawValue: "owned"))
        }
        async let one: Void = session.close()
        async let two: Void = session.close()
        try await one
        try await two
        await #expect(throws: Tailcat.Failure.closed) { try await child.connectTCP() }
        #expect(closes.count == 1)
    }
}

/// The lock protects the signal state; continuations always resume outside it.
final class FoundationSignal: @unchecked Sendable {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()
    private var signaled = false
    var isSignaled: Bool { lock.withLock { signaled } }
    func signal() {
        let pending = lock.withLock {
            signaled = true
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if signaled { return true }
                continuations.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }
}
