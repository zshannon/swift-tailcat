extension Tailcat.Session {
    /// The pinned official README, available offline to Swift-only consumers.
    /// Its relative links refer to the upstream repository layout.
    public func upstreamREADME() async throws -> String {
        try await request("documentation.readme")
    }
}
