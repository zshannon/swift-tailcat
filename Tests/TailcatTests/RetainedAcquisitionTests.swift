import Foundation
@testable import Tailcat
import Testing

@Suite struct RetainedAcquisitionTests {
    @Test func realBridgeCancellationJoinsSlowUnpublishedCleanup() async throws {
        let allocated = FoundationSignal()
        let cleanupEntered = FoundationSignal()
        let cleanupRelease = FoundationSignal()
        let conversionRelease = FoundationSignal()
        let returned = FoundationSignal()
        let session = try Tailcat.Session()
        let task = Task {
            defer { returned.signal() }
            return try await session.acquireLive("cache.create") { (response: HandleResponse) in
                allocated.signal()
                await conversionRelease.wait()
                return Tailcat.Cache(abort: {}, close: {
                    cleanupEntered.signal()
                    await cleanupRelease.wait()
                    try await session.closeResource(response.handle)
                })
            }
        }
        await allocated.wait()
        task.cancel()
        conversionRelease.signal()
        await cleanupEntered.wait()
        #expect(!returned.isSignaled)
        cleanupRelease.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await session.close()
    }

    @Test func realBridgeAllocationCanceledAtHandoffClosesHandleBeforeThrowing() async throws {
        let entered = FoundationSignal()
        let release = FoundationSignal()
        let handle = RetainedHandle()
        let session = try Tailcat.Session()
        let task = Task {
            try await session.acquireLive("cache.create") { (response: HandleResponse) in
                await handle.set(response.handle)
                entered.signal()
                await release.wait()
                return Tailcat.Cache(handle: response.handle, runtime: session)
            }
        }
        await entered.wait()
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        let allocated = await handle.value
        await #expect(throws: Tailcat.Failure.closed) {
            try await session.requestValue("cache.get", ["handle": .integer(allocated), "url": .string("https://owned.invalid")])
        }
        try await session.close()
    }

    @Test func canceledLiveConversionJoinsUnpublishedHandleCleanup() async throws {
        let entered = FoundationSignal()
        let release = FoundationSignal()
        let cleaned = EventCounter()
        let parent = Ownership(abort: {}, close: {})
        let task = Task {
            try await acquire(parent: parent, ownership: { $0.ownership }) {
                try await retainedResponse(dispose: { _ in cleaned.increment() }, request: {
                    .object(["handle": .integer(73)])
                }) { (response: HandleResponse) in
                    entered.signal()
                    await release.wait()
                    return Tailcat.Client(abort: {}, close: { cleaned.increment() })
                }
            }
        }
        await entered.wait()
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cleaned.count == 1)
        try await parent.close()
    }

    @Test func failedLiveResponseDecodingJoinsDisposalUncancelled() async throws {
        let entered = FoundationSignal()
        let release = FoundationSignal()
        let cleaned = FoundationSignal()
        let task = Task {
            try await retainedResponse(dispose: { handle in
                #expect(handle == 73)
                #expect(!Task.isCancelled)
                await release.wait()
                cleaned.signal()
            }, request: {
                entered.signal()
                return .object(["address": .string("[::]:65536"), "handle": .integer(73)])
            }) { (response: ServiceResponse) in response.handle }
        }
        await entered.wait()
        task.cancel()
        #expect(!cleaned.isSignaled)
        release.signal()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(cleaned.isSignaled)
    }

    @Test func parentShutdownDuringLiveConversionJoinsCleanup() async throws {
        let parent = Ownership(abort: {}, close: {})
        let closes = EventCounter()
        await #expect(throws: Tailcat.Failure.closed) {
            try await acquire(parent: parent, ownership: { $0.ownership }) {
                try await retainedResponse(dispose: { _ in }, request: { .object(["handle": .integer(1)]) }) { (response: HandleResponse) in
                    parent.requestShutdown()
                    return Tailcat.Client(abort: {}, close: { closes.increment() })
                }
            }
        }
        #expect(closes.count == 1)
        try await parent.close()
    }
}

private actor RetainedHandle {
    var value: Int64 = 0
    func set(_ value: Int64) { self.value = value }
}
