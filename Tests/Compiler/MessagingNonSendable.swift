import Tailcat
final class Mutable: Codable { var value = 1 }
enum Operation: Request { typealias Input = Mutable; static let event = "non-sendable" }
let handler = Handle(Operation.self) { _ in }
