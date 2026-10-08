import Tailcat
enum Operation: Request { typealias Input = Int; static let event = "wrong" }
func wrong(_ connection: Tailcat.Connection) async throws { try await connection.call(Operation.self, input: "wrong") }
