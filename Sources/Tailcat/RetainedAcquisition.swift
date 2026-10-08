import Foundation

/// Decode and conversion failures must dispose a returned handle before escaping.
/// Disposal runs uncancelled, including when the caller lost the publication race.
func retainedResponse<Response: Decodable, Resource: Sendable>(
    dispose: @escaping @Sendable (Int64) async -> Void,
    request: @Sendable () async throws -> Tailcat.JSONValue,
    convert: (Response) async throws -> Resource
) async throws -> Resource {
    let value = try await request()
    do { return try await convert(value.decode()) }
    catch {
        if let handle = value["handle"]?.integerValue {
            await Task.detached { await dispose(handle) }.value
        }
        throw error
    }
}

extension TailcatResource {
    func retained<Response: Decodable, Resource: Sendable>(
        _ method: String, _ input: Tailcat.Metadata = [:],
        convert: (Response) async throws -> Resource
    ) async throws -> Resource {
        try await retainedResponse(dispose: { handle in try? await self.runtime.closeResource(handle) },
                                   request: { try await self.requestValue(method, input) }, convert: convert)
    }

    func acquireLive<Response: Decodable, Resource: TailcatResource>(
        _ method: String, _ input: Tailcat.Metadata = [:],
        convert: @Sendable (Response) async throws -> Resource
    ) async throws -> Resource {
        try await acquire(parent: ownership, ownership: { $0.ownership }) {
            try await self.retained(method, input, convert: convert)
        }
    }
}

extension Tailcat.Session {
    func retained<Response: Decodable, Resource: Sendable>(
        _ method: String, _ input: Tailcat.Metadata = [:],
        convert: (Response) async throws -> Resource
    ) async throws -> Resource {
        try await retainedResponse(dispose: { handle in try? await self.closeResource(handle) },
                                   request: { try await self.requestValue(method, input) }, convert: convert)
    }

    func acquireLive<Response: Decodable, Resource: TailcatResource>(
        _ method: String, _ input: Tailcat.Metadata = [:],
        convert: @Sendable (Response) async throws -> Resource
    ) async throws -> Resource {
        try await acquire(parent: ownership, ownership: { $0.ownership }) {
            try await self.retained(method, input, convert: convert)
        }
    }
}
