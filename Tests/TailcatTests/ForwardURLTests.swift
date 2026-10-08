import Foundation
@testable import Tailcat
import Testing

extension LoopbackTests {
    // A port-80-only URL branch would fail before the actual HTTP round trip.
    @Test func arbitraryForwardPortHasUsableBrowserURL() async throws {
        let context = try await LoopbackContext.create()
        let listener = try await context.server.listen(address: ":0")
        let port = try #require(Int(listener.address.split(separator: ":").last ?? ""))
        #expect(port != 80)
        let forwarded = try await context.client.forwardTCP(bind: "0.0.0.0:0", port: port)
        let url = try #require(forwarded.url)
        #expect(url.host == "127.0.0.1" && url.path == "/" && url.scheme == "http")
        let accepted = Task {
            let connection = try await listener.accept()
            try await connection.setDeadlines(read: .now.addingTimeInterval(5))
            let request = try #require(try await connection.read())
            #expect(String(decoding: request, as: UTF8.self).hasPrefix("GET / HTTP/1.1\r\n"))
            try await connection.write(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nowned".utf8))
            try await connection.close()
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: url)
        #expect(data == Data("owned".utf8))
        try await accepted.value
        try await forwarded.close()
        try await context.runtime.close()
    }

    // Endpoint forwarding and IPv6 must use the bound local endpoint, not a tunnel IP.
    @Test func endpointForwardHasIPv6BrowserURL() async throws {
        let context = try await LoopbackContext.create()
        let ip = try await context.server.tunnelIP().rawValue
        let forwarded = try await context.client.forwardTCP(bind: "[::1]:0", endpoint: "[\(ip)]:8080")
        let url = try #require(forwarded.url)
        #expect(url.absoluteString.hasPrefix("http://[::1]:"))
        #expect(url.path == "/")
        try await context.runtime.close()
    }
}
