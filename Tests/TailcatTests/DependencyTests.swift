import Dependencies
import Foundation
import IssueReporting
@testable import Tailcat
import Testing

@Suite struct DependencyTests {
    @Test func ownerDiagnosticUsesAcquisitionDependencies() async throws {
        let reported = FoundationSignal()
        let values = DiagnosticValues()
        let dependency = Tailcat(makeSession: { _ in
            Tailcat.Session(abort: {}, close: { throw Tailcat.Failure.operationFailed("cleanup") })
        })
        let session = try await withDependencies {
            $0.foundationMarker = "acquisition"
        } operation: {
            try await dependency.makeSession(configuration: .init(onDiagnostic: { _ in
                @Dependency(\.foundationMarker) var marker
                values.append(marker)
                reported.signal()
            }))
        }
        try? await session.close()
        await reported.wait()
        #expect(values.values == ["acquisition"])
    }

    @Test func escapedLoggerUsesRegistrationDependencies() async {
        let values = DiagnosticValues()
        let bridge = withDependencies {
            $0.foundationMarker = "registered"
        } operation: {
            LoggerBridge { _ in
                @Dependency(\.foundationMarker) var marker
                values.append(marker)
            }
        }
        await Task.detached { bridge.log(0, message: "message") }.value
        #expect(values.values == ["registered"])
    }

    @Test func explicitTestAndPreviewValuesNeverAcquireLiveResources() async {
        @Dependency(\.tailcat) var injected
        for value in [Tailcat(), Tailcat.testValue, Tailcat.previewValue, injected] {
            await expectReportsIssue {
                await #expect(throws: Tailcat.Failure.unimplemented("Tailcat.makeSession")) {
                    try await value.makeSession()
                }
            } matching: { $0.description == "Issue reported: Unimplemented Tailcat operation: Tailcat.makeSession" }
            expectReportsIssue {
                #expect(throws: Tailcat.Failure.unimplemented("Tailcat.configureVerbose")) {
                    try value.configureVerbose(true)
                }
            } matching: { $0.description == "Issue reported: Unimplemented Tailcat operation: Tailcat.configureVerbose" }
            expectReportsIssue {
                #expect(throws: Tailcat.Failure.unimplemented("Tailcat.generateIdentity")) {
                    try value.generateIdentity()
                }
            } matching: { $0.description == "Issue reported: Unimplemented Tailcat operation: Tailcat.generateIdentity" }
            expectReportsIssue {
                #expect(throws: Tailcat.Failure.unimplemented("Tailcat.generatePresharedKey")) {
                    try value.generatePresharedKey()
                }
            } matching: { $0.description == "Issue reported: Unimplemented Tailcat operation: Tailcat.generatePresharedKey" }
        }
    }

    @Test func liveRootGeneratesValuesWithoutAcquiringSession() throws {
        var dependency = Tailcat.liveValue
        dependency.makeSession = { _ in
            Issue.record("synchronous generation acquired a session")
            throw Tailcat.Failure.operationFailed("unexpected session")
        }
        let identity = try dependency.generateIdentity()
        let key = try dependency.generatePresharedKey()
        #expect(!identity.privateKey.isEmpty)
        #expect(key.data.count == 32 && !key.isZero)
    }

    @Test func dependencyOverrideCreatesIndependentGraphsAndChangesOnlyFutureAcquisitions() async throws {
        struct Feature {
            @Dependency(\.tailcat) var tailcat
        }
        let closes = EventCounter()
        let feature = withDependencies {
            $0.tailcat = Tailcat(makeSession: { _ in
                Tailcat.Session(abort: {}, close: { closes.increment() })
            })
        } operation: { Feature() }
        let first = try await feature.tailcat.makeSession()
        let second = try await feature.tailcat.makeSession()
        #expect(first !== second)
        try await first.close()
        #expect(closes.count == 1)
        let third = try await withDependencies {
            $0.tailcat.makeSession = { _ in Tailcat.Session(abort: {}, close: {}) }
        } operation: {
            @Dependency(\.tailcat) var dependency
            return try await dependency.makeSession()
        }
        try await second.close()
        try await third.close()
        #expect(closes.count == 2)
    }

    @Test @MainActor func scopePreservesActorIsolationAndNonSendableResult() async throws {
        final class ResultBox { var count = 0 }
        let expected = ResultBox()
        let dependency = Tailcat(makeSession: { _ in Tailcat.Session(abort: {}, close: {}) })
        let actual = try await dependency.withSession { _ in
            expected.count += 1
            return expected
        }
        #expect(actual === expected)
        #expect(actual.count == 1)
    }
}

private enum FoundationMarker: DependencyKey {
    static let liveValue = "live"
    static let testValue = "test"
}

extension DependencyValues {
    fileprivate var foundationMarker: String {
        get { self[FoundationMarker.self] }
        set { self[FoundationMarker.self] = newValue }
    }
}

private final class DiagnosticValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
