import Tailcat
enum Operation: Request { typealias Inbound = Int; static let event = "duplex" }
let handler = Handle(Operation.self) { _ in }
