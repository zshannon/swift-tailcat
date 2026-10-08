@_exported public import Dependencies
import Foundation
import IssueReporting
import OSLog
@preconcurrency import TailcatCore

/// An inert dependency value. Each acquisition creates an independent owned graph.
/// liveValue installs bridge providers; Tailcat(), testValue and previewValue use unimplemented stubs.
public struct Tailcat: DependencyKey, Sendable {
    public var configureVerbose: @Sendable (Bool) throws -> Void
    public var generateIdentity: @Sendable () throws -> Identity
    public var generatePresharedKey: @Sendable () throws -> PresharedKey
    private var sessionProvider: @Sendable (Session.Configuration) async throws -> Session

    public var makeSession: @Sendable (Session.Configuration) async throws -> Session {
        get {
            let provider = sessionProvider
            return { configuration in
                let dependencies = withEscapedDependencies { $0 }
                return try await acquire(onDiagnostic: { diagnostic in
                    dependencies.yield { configuration.onDiagnostic(diagnostic) }
                }, ownership: { $0.ownership }) {
                    try await provider(configuration)
                }
            }
        }
        set { sessionProvider = newValue }
    }

    public init(
        configureVerbose: @escaping @Sendable (Bool) throws -> Void = { _ in try unimplementedRoot("Tailcat.configureVerbose") },
        generateIdentity: @escaping @Sendable () throws -> Identity = { try unimplementedRoot("Tailcat.generateIdentity") },
        generatePresharedKey: @escaping @Sendable () throws -> PresharedKey = { try unimplementedRoot("Tailcat.generatePresharedKey") },
        makeSession: @escaping @Sendable (Session.Configuration) async throws -> Session = { _ in try unimplementedRoot("Tailcat.makeSession") }
    ) {
        self.configureVerbose = configureVerbose
        self.generateIdentity = generateIdentity
        self.generatePresharedKey = generatePresharedKey
        sessionProvider = makeSession
    }

    public static var liveValue: Self {
        Self(
            configureVerbose: { enabled in
                var error: NSError?
                MobileConfigureVerbose(enabled, &error)
                if let error { throw error }
            },
            generateIdentity: {
                var error: NSError?
                let json = MobileGenerateIdentity(&error)
                if let error { throw error }
                return try decodeBridge(json)
            },
            generatePresharedKey: {
                var error: NSError?
                let json = MobileGeneratePresharedKey(&error)
                if let error { throw error }
                return try decodeBridge(json)
            },
            makeSession: { _ in try Session() }
        )
    }
    public static var previewValue: Self { Self() }
    public static var testValue: Self { Self() }

    public func makeSession(configuration: Session.Configuration = .init()) async throws -> Session {
        try await makeSession(configuration)
    }

    public func withSession<Result>(
        configuration: Session.Configuration = .init(),
        isolation: isolated (any Actor)? = #isolation,
        operation: (Session) async throws -> Result
    ) async throws -> Result {
        let session = try await makeSession(configuration: configuration)
        return try await withTaskCancellationHandler {
            let value: Result
            do {
                try Task.checkCancellation()
                value = try await operation(session)
            } catch {
                session.requestShutdown()
                try? await session.close()
                throw error
            }
            try await session.close()
            return value
        } onCancel: { session.requestShutdown() }
    }

    public struct Diagnostic: Sendable {
        public let message: String
        public let operation: String
        public init(message: String, operation: String) {
            self.message = message
            self.operation = operation
        }
    }

    public enum Discovery {}
    public enum Performance {}
}

extension Tailcat.Session {
    public struct Configuration: Sendable {
        public var onDiagnostic: @Sendable (Tailcat.Diagnostic) -> Void
        public init(onDiagnostic: @escaping @Sendable (Tailcat.Diagnostic) -> Void = { diagnostic in
            Logger(subsystem: "Tailcat", category: "cleanup").error("\(diagnostic.operation): \(diagnostic.message)")
        }) { self.onDiagnostic = onDiagnostic }
    }
}

extension DependencyValues {
    public var tailcat: Tailcat {
        get { self[Tailcat.self] }
        set { self[Tailcat.self] = newValue }
    }
}

private func decodeBridge<Value: Decodable>(_ json: String?) throws -> Value {
    guard let json else { throw Tailcat.Failure.operationFailed("bridge returned no value") }
    return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
}

@usableFromInline
func unimplementedRoot<Value>(_ operation: String) throws -> Value {
    reportIssue("Unimplemented Tailcat operation: \(operation)")
    throw Tailcat.Failure.unimplemented(operation)
}
