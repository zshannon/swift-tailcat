import Tailcat
struct Unencoded: Sendable {}
enum Operation: Request { typealias Input = Unencoded; static let event = "unencoded" }
let handler = Handle(Operation.self) { _ in }
