import Foundation

extension Tailcat.SSH {
public enum AuthorizedKeySource: Sendable {
    case file(URL)
    case github(String)
    case text(String)
}
}

extension Tailcat.Session {
    /// Loads explicit sources and validates all authorized-key lines with official Tailcat.
    public func loadSSHAuthorizedKeys(sources: [Tailcat.SSH.AuthorizedKeySource],
        fetch: @Sendable (URL) async throws -> Data = fetchSSHKeys) async throws -> [String] {
        try Task.checkCancellation()
        try ownership.checkOpen()
        if let keySourcesProvider { return try await keySourcesProvider(sources) }
        var texts: [String] = []
        for source in sources {
            try Task.checkCancellation()
            try ownership.checkOpen()
            let data: Data
            switch source {
            case .file(let url):
                guard url.isFileURL else { throw Tailcat.Failure.invalidInput("key source requires a file URL") }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                data = try file.read(upToCount: 1_048_577) ?? Data()
            case .github(let user):
                guard user.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", options: .regularExpression) != nil,
                      let url = URL(string: "https://github.com/\(user).keys") else {
                    throw Tailcat.Failure.invalidInput("invalid GitHub username")
                }
                data = try await fetch(url)
            case .text(let text): data = Data(text.utf8)
            }
            guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
                throw Tailcat.Failure.invalidInput("authorized key sources must be UTF-8 and at most 1 MiB")
            }
            try await validateSSHAuthorizedKeys([text])
            texts.append(text)
        }
        try await validateSSHAuthorizedKeys(texts)
        return texts
    }
}

public func fetchSSHKeys(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.setValue("swift-tailcat", forHTTPHeaderField: "User-Agent")
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw Tailcat.Failure.operationFailed("SSH key source returned an unsuccessful HTTP status")
    }
    var result = Data()
    for try await byte in bytes {
        try Task.checkCancellation()
        guard result.count < 1_048_576 else { throw Tailcat.Failure.invalidInput("SSH key source exceeds 1 MiB") }
        result.append(byte)
    }
    return result
}
