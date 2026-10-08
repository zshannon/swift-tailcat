extension Tailcat {
public enum Version {
    public static let bridgeProtocol = 1
    public static let upstreamCommit = "b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f"
    public static let upstreamVersion = "v0.7.1-0.20260929145319-b4dc28e8aa89"
}
}

extension Tailcat.Client {
    /// Poll direct-path discovery with cancellation rather than a process-wide CLI loop.
    public func waitForDirectPath(interval: Duration = .milliseconds(250)) async throws -> Tailcat.Discovery.Result {
        guard interval > .zero else { throw Tailcat.Failure.invalidInput("poll interval must be positive") }
        while true {
            try Task.checkCancellation()
            let result = try await discoPing()
            if result.isDirect { return result }
            try await Task.sleep(for: interval)
        }
    }
}
