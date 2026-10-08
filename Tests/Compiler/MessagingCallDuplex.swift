import Tailcat
enum Operation: Request { typealias Yield = Int; static let event = "duplex" }
func wrong(_ connection: Tailcat.Connection) async throws { try await connection.call(Operation.self) }
