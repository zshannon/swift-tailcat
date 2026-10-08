import Foundation

/// All mutable ownership state is protected by `lock`. Provider callbacks,
/// diagnostics and continuation resumes execute after releasing every lock.
final class Ownership: @unchecked Sendable {
    private let abort: @Sendable () -> Void
    private var children: [ObjectIdentifier: Ownership] = [:]
    private var claimed = false
    private let completion = CloseCompletion()
    private let diagnostics = OwnershipDiagnostics()
    private let finish: @Sendable () async throws -> Void
    private var isClosing = false
    private let lock = NSLock()
    private weak var parent: Ownership?
    private var pendingAcquisitions: [ObjectIdentifier: CloseCompletion] = [:]

    init(abort: @escaping @Sendable () -> Void, close: @escaping @Sendable () async throws -> Void) {
        self.abort = abort
        finish = close
    }

    deinit { requestShutdown() }

    func checkOpen() throws {
        try lock.withLock { if isClosing { throw Tailcat.Failure.closed } }
    }

    var isShuttingDown: Bool { lock.withLock { isClosing } }
    var transferOwner: Ownership? { lock.withLock { parent } }

    func belongs(to owner: Ownership) -> Bool {
        var current: Ownership? = self
        while let node = current {
            if node === owner { return true }
            current = node.transferOwner
        }
        return false
    }

    func claimRoot(onDiagnostic: @escaping @Sendable (Tailcat.Diagnostic) -> Void) throws {
        try lock.withLock {
            guard !claimed else { throw Tailcat.Failure.ownershipConflict }
            claimed = true
            diagnostics.install(onDiagnostic)
        }
    }

    /// Pair locks have a stable address order, including invalid provider graphs.
    /// Already-owned returns are rejected before deciding whether to dispose them.
    func attach(_ child: Ownership) throws {
        guard child !== self else { throw Tailcat.Failure.ownershipConflict }
        let first = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
            < UInt(bitPattern: Unmanaged.passUnretained(child).toOpaque()) ? self : child
        let second = first === self ? child : self
        first.lock.lock()
        second.lock.lock()
        defer { second.lock.unlock(); first.lock.unlock() }
        guard !child.claimed else { throw Tailcat.Failure.ownershipConflict }
        child.claimed = true
        child.diagnostics.inherit(diagnostics)
        guard !isClosing else { throw Tailcat.Failure.closed }
        child.parent = self
        children[ObjectIdentifier(child)] = child
    }

    /// Admission and shutdown share the lock. The reservation stays live through
    /// provider execution and any joined disposal of an unpublished result.
    fileprivate func reserveAcquisition() throws -> CloseCompletion {
        let reservation = CloseCompletion()
        try lock.withLock {
            guard !isClosing else { throw Tailcat.Failure.closed }
            pendingAcquisitions[ObjectIdentifier(reservation)] = reservation
        }
        return reservation
    }

    fileprivate func finishAcquisition(_ reservation: CloseCompletion) {
        _ = lock.withLock { pendingAcquisitions.removeValue(forKey: ObjectIdentifier(reservation)) }
        reservation.complete(.success(()))
    }

    fileprivate func callbackScope(inheriting owners: Set<ObjectIdentifier>) -> Set<ObjectIdentifier> {
        var owners = owners
        var current: Ownership? = self
        while let owner = current {
            owners.insert(ObjectIdentifier(owner))
            current = owner.transferOwner
        }
        return owners
    }

    func requestShutdown() { requestShutdown(inheriting: CleanupScope.owners) }

    fileprivate func requestShutdown(inheriting owners: Set<ObjectIdentifier>) {
        let work = lock.withLock { () -> ([Ownership], [CloseCompletion])? in
            guard !isClosing else { return nil }
            isClosing = true
            return (Array(children.values), Array(pendingAcquisitions.values))
        }
        guard let (children, reservations) = work else { return }
        let callbackOwners = callbackScope(inheriting: owners)
        // Synchronous interruption precedes joining and may forward shutdown.
        CleanupScope.$owners.withValue(callbackOwners) { abort() }
        for child in children { child.requestShutdown(inheriting: callbackOwners) }
        let completion = completion
        let finish = finish
        let id = ObjectIdentifier(self)
        let parent = lock.withLock { self.parent }
        let diagnostics = diagnostics
        Task.detached {
            var diagnostic: Tailcat.Diagnostic?
            var failure: (any Error)?
            for reservation in reservations { try? await reservation.wait() }
            for child in children {
                do { try await child.close() } catch { if failure == nil { failure = error } }
            }
            do { try await CleanupScope.$owners.withValue(callbackOwners) { try await finish() } } catch {
                diagnostic = .init(message: String(describing: error), operation: "close")
                if failure == nil { failure = error }
            }
            if let failure {
                completion.complete(.failure(failure))
            } else {
                completion.complete(.success(()))
            }
            parent?.remove(id)
            if let diagnostic { diagnostics.report(diagnostic) }
        }
    }

    func close() async throws {
        guard !CleanupScope.owners.contains(ObjectIdentifier(self)) else { throw Tailcat.Failure.ownershipConflict }
        requestShutdown()
        try await completion.wait()
    }

    private func remove(_ id: ObjectIdentifier) { _ = lock.withLock { children.removeValue(forKey: id) } }
}

/// Child sinks retain their parent sink, so a root acquired after construction
/// can install its diagnostic environment once for the existing graph. The lock
/// protects the links/callback; traversal and callbacks happen outside the lock.
private final class OwnershipDiagnostics: @unchecked Sendable {
    private var handler: (@Sendable (Tailcat.Diagnostic) -> Void)?
    private let lock = NSLock()
    private var parent: OwnershipDiagnostics?
    func inherit(_ parent: OwnershipDiagnostics) { lock.withLock { self.parent = parent } }
    func install(_ handler: @escaping @Sendable (Tailcat.Diagnostic) -> Void) { lock.withLock { self.handler = handler } }
    func report(_ diagnostic: Tailcat.Diagnostic) {
        let (handler, parent) = lock.withLock { (handler, parent) }
        if let parent { parent.report(diagnostic) }
        else { handler?(diagnostic) }
    }
}

/// Cancellation and provider handoff use the same lock. Only an unowned result
/// may be disposed; the ownership-conflict path never invokes foreign cleanup.
final class Acquisition: @unchecked Sendable {
    private var admitted = false
    private var canceled = false
    private let lock = NSLock()
    func admit() throws {
        try lock.withLock {
            if canceled { throw CancellationError() }
            admitted = true
        }
    }
    func finish() { lock.withLock { admitted = false } }
    func cancel(interrupt: @Sendable () -> Void) {
        let shouldInterrupt = lock.withLock { canceled = true; return admitted }
        if shouldInterrupt { interrupt() }
    }
    func handoff(_ child: Ownership, parent: Ownership?, onDiagnostic: @escaping @Sendable (Tailcat.Diagnostic) -> Void) throws {
        try lock.withLock {
            if let parent { try parent.attach(child) }
            else { try child.claimRoot(onDiagnostic: onDiagnostic) }
            if canceled { throw CancellationError() }
            try child.checkOpen()
            admitted = false
        }
    }
}

private enum CleanupScope {
    @TaskLocal static var owners: Set<ObjectIdentifier> = []
}

func acquire<Resource: Sendable>(
    onCancel: @escaping @Sendable () -> Void = {},
    onDiagnostic: @escaping @Sendable (Tailcat.Diagnostic) -> Void = { _ in },
    parent: Ownership? = nil,
    ownership: @escaping @Sendable (Resource) -> Ownership,
    provider: @Sendable () async throws -> Resource
) async throws -> Resource {
    try Task.checkCancellation()
    let reservation = try parent?.reserveAcquisition()
    defer { if let parent, let reservation { parent.finishAcquisition(reservation) } }
    let callbackOwners = parent?.callbackScope(inheriting: CleanupScope.owners) ?? CleanupScope.owners
    let acquisition = Acquisition()
    return try await withTaskCancellationHandler {
        try acquisition.admit()
        defer { acquisition.finish() }
        let resource = try await CleanupScope.$owners.withValue(callbackOwners) { try await provider() }
        let child = ownership(resource)
        do {
            try acquisition.handoff(child, parent: parent, onDiagnostic: onDiagnostic)
            return resource
        } catch Tailcat.Failure.ownershipConflict {
            throw Tailcat.Failure.ownershipConflict
        } catch {
            // A closing parent rejects attachment before setting the parent
            // link. Detached cleanup therefore needs this explicit scope union.
            child.requestShutdown(inheriting: callbackOwners)
            try? await child.close()
            throw error
        }
    } onCancel: { acquisition.cancel(interrupt: onCancel) }
}

/// The result and waiters are guarded by the lock. Close waiters are deliberately
/// uncancelled so every caller observes the single completed cleanup outcome.
fileprivate final class CloseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    func complete(_ result: Result<Void, any Error>) {
        let pending = lock.withLock {
            guard self.result == nil else { return [CheckedContinuation<Void, any Error>]() }
            self.result = result
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume(with: result) }
    }
    func wait() async throws {
        try await withCheckedThrowingContinuation { waiter in
            let result: Result<Void, any Error>? = lock.withLock {
                if let result = self.result { return result }
                waiters.append(waiter)
                return nil
            }
            if let result { waiter.resume(with: result) }
        }
    }
}
