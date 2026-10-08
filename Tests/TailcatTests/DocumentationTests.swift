import Foundation
@testable import Tailcat
import Testing

// The exported upstream README must remain available to a Swift-only consumer.
@Test func upstreamDocumentationIsAvailableWithoutRepositoryFiles() async throws {
    let runtime = try TailcatRuntime()
    let text = try await runtime.upstreamREADME()
    #expect(text.contains("Tailscale without Tailscale, by Tailscale"))
    #expect(text.contains("tailcat forward"))
    #expect(text.contains("tailcat.png"))
    try await runtime.close()
}
