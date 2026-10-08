import Foundation
import Tailcat
import Testing

private enum RejectedCleanup: Equatable, Sendable {
    case child
    case descendant
    case forwardedAbort
}

@Suite(.timeLimit(.minutes(1))) struct AcquisitionAdmissionTests {
    @Test func sessionCloseJoinsCooperativeUnpublishedCleanup() async throws {
        let aborted = FoundationSignal()
        let cleaned = FoundationSignal()
        let cleanupEntered = FoundationSignal()
        let entered = FoundationSignal()
        let release = FoundationSignal()
        let session = Tailcat.Session(abort: { aborted.signal() }, close: {}, makeClient: { _, _ in
            let unpublished = Tailcat.Client(abort: {}, close: {
                cleanupEntered.signal()
                await release.wait()
                cleaned.signal()
            })
            entered.signal()
            await withTaskCancellationHandler { await aborted.wait() } onCancel: { aborted.signal() }
            try await unpublished.close()
            throw Tailcat.Failure.closed
        })
        let acquisition = Task { try await session.makeClient(address: .init(rawValue: "admission")) }
        await entered.wait()
        let closing = Task {
            try await session.close()
            #expect(cleaned.isSignaled)
            // Release even when the old implementation completes too early.
            release.signal()
        }
        await cleanupEntered.wait()
        // Admission and cleanup entry are proven by events. This deadline only
        // releases held cleanup, including on a regressed early-close path.
        let escape = admissionEscape(release)
        await #expect(throws: Tailcat.Failure.closed) { try await acquisition.value }
        try await closing.value
        escape.cancel()
        await escape.value
        #expect(cleaned.isSignaled)
        try await session.close()
    }

    @Test(arguments: [false, true])
    func providerCannotJoinItsParentOrAncestor(_ ancestor: Bool) async throws {
        let attempt = AdmissionCloseAttempt()
        let entered = FoundationSignal()
        let reference = AdmissionCloseReference()
        let release = FoundationSignal()
        let client = Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
            entered.signal()
            attempt.start(release: release) { try await reference.close() }
            await release.wait()
            #expect(attempt.completed.isSignaled)
            return Tailcat.TCPConnection(abort: {}, close: {})
        })
        let session = Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in client })
        _ = try await session.makeClient(address: .init(rawValue: "admission"))
        await reference.set { if ancestor { try await session.close() } else { try await client.close() } }
        let acquisition = Task { try await client.connectTCP() }
        await entered.wait()
        let escape = admissionEscape(release)
        let result = await acquisition.result
        if case .failure(let error) = result { Issue.record("provider close revoked admission: \(error)") }
        try await session.close()
        await attempt.join()
        #expect(attempt.conflicts.count == 1)
        escape.cancel()
        await escape.value
    }

    @Test(arguments: [RejectedCleanup.child, .descendant, .forwardedAbort])
    fileprivate func rejectedChildCleanupCannotJoinClosingParent(_ variant: RejectedCleanup) async throws {
        let attempt = AdmissionCloseAttempt()
        let cleanupEntered = FoundationSignal()
        let entered = FoundationSignal()
        let promptCompletions = EventCounter()
        let reference = AdmissionCloseReference()
        let releaseCleanup = FoundationSignal()
        let returnChild = FoundationSignal()
        let cleanup: @Sendable () async -> Void = {
            cleanupEntered.signal()
            attempt.start(release: releaseCleanup) { try await reference.close() }
            await releaseCleanup.wait()
            if attempt.completed.isSignaled { promptCompletions.increment() }
        }
        let session = Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
            let connection = Tailcat.TCPConnection(abort: {}, close: {
                if variant != .child { await cleanup() }
            })
            let client = Tailcat.Client(abort: {
                if variant == .forwardedAbort { connection.requestShutdown() }
            }, close: {
                if variant == .child { await cleanup() }
            }, connectTCP: { _ in connection })
            // The descendant is already owned before Session rejects this Client.
            if variant != .child { _ = try await client.connectTCP() }
            entered.signal()
            await returnChild.wait()
            return client
        })
        await reference.set { try await session.close() }
        let acquisition = Task { try await session.makeClient(address: .init(rawValue: "admission")) }
        await entered.wait()
        #expect(!cleanupEntered.isSignaled)
        session.requestShutdown()
        let closing = Task { try await session.close() }
        returnChild.signal()
        await cleanupEntered.wait()
        let escape = admissionEscape(releaseCleanup)
        await #expect(throws: Tailcat.Failure.closed) { try await acquisition.value }
        try await closing.value
        await attempt.join()
        #expect(attempt.conflicts.count == 1)
        #expect(promptCompletions.count == 1)
        escape.cancel()
        await escape.value
    }
}

private func admissionEscape(_ release: FoundationSignal) -> Task<Void, Never> {
    Task {
        do { try await Task.sleep(for: .seconds(1)); release.signal() } catch {}
    }
}

private actor AdmissionCloseReference {
    private var operation: (@Sendable () async throws -> Void)?
    func close() async throws { try await operation?() }
    func set(_ operation: @escaping @Sendable () async throws -> Void) { self.operation = operation }
}

/// The lock protects the task handle. The callback and join run outside it.
private final class AdmissionCloseAttempt: @unchecked Sendable {
    let completed = FoundationSignal()
    let conflicts = EventCounter()
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func start(release: FoundationSignal, operation: @escaping @Sendable () async throws -> Void) {
        let work = Task {
            do { try await operation() }
            catch Tailcat.Failure.ownershipConflict { conflicts.increment() }
            catch {}
            completed.signal()
            release.signal()
        }
        lock.withLock { task = work }
    }
    func join() async { await lock.withLock { task }?.value }
}
