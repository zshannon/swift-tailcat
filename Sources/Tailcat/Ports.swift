import Foundation

/// Validate in Int before conversion to bridge or socket integer types.
enum Ports {
    enum Context { case local; case remote; case stun }

    static func validate(_ port: Int, as context: Context) throws {
        let lower: Int
        switch context {
        case .local: lower = 0
        case .remote: lower = 1
        case .stun: lower = -1
        }
        guard (lower...65_535).contains(port) else {
            throw Tailcat.Failure.invalidInput("port must be in \(lower)...65535")
        }
    }

    static func validateDERP(_ fields: Tailcat.Metadata) throws {
        for (key, value) in fields {
            if key == "DERPPort" || key == "STUNPort" {
                guard let integer = value.integerValue, let port = Int(exactly: integer) else {
                    throw Tailcat.Failure.invalidInput("\(key) must be an integer port")
                }
                try validate(port, as: key == "STUNPort" ? .stun : .local)
            } else if case .object(let object) = value {
                try validateDERP(object)
            } else if case .array(let array) = value {
                for case .object(let object) in array { try validateDERP(object) }
            }
        }
    }
}
