import Foundation

extension Tailcat {
public enum Failure: Error, Equatable, Sendable {
    case closed
    case invalidInput(String)
    case operationFailed(String)
    case ownershipConflict
    case unimplemented(String)
    case unsupported(String)
}
}

extension Tailcat.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .closed: "The Tailcat resource is closed."
        case .invalidInput(let message): message
        case .operationFailed(let message): message
        case .ownershipConflict: "The resource already belongs to an owner."
        case .unimplemented(let operation): "Unimplemented Tailcat operation: \(operation)"
        case .unsupported(let message): message
        }
    }
}
