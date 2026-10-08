import Dependencies
import Foundation

struct RequestBindings<R: Request>: Sendable {
    let inbound: MessageCodec<R.Inbound>
    let input: MessageCodec<R.Input>
    let output: MessageCodec<R.Output>
    let yield: MessageCodec<R.Yield>
}
extension Tailcat {
    public struct Handler: Sendable {
        public var event: String { route.event }
        public var version: Int { route.version }
        let route: MessageRoute
        let invoke: @Sendable (Data, MessageFlow) async throws -> Void
    }
}
@resultBuilder public enum HandlerBuilder {
    public static func buildArray(_ components: [[Tailcat.Handler]]) -> [Tailcat.Handler] { components.flatMap { $0 } }
    public static func buildBlock(_ components: [Tailcat.Handler]...) -> [Tailcat.Handler] { components.flatMap { $0 } }
    public static func buildEither(first: [Tailcat.Handler]) -> [Tailcat.Handler] { first }
    public static func buildEither(second: [Tailcat.Handler]) -> [Tailcat.Handler] { second }
    public static func buildExpression(_ handler: Tailcat.Handler) -> [Tailcat.Handler] { [handler] }
    public static func buildOptional(_ component: [Tailcat.Handler]?) -> [Tailcat.Handler] { component ?? [] }
}
func makeHandler<R>(_ bindings: RequestBindings<R>, handler: @escaping @Sendable (R.Input, Tailcat.Stream<R.Inbound, R.Yield>) async throws -> R.Output) -> Tailcat.Handler {
    let dependencies = withEscapedDependencies { $0 }
    return Tailcat.Handler(route: MessageRoute(event: R.event, version: R.version)) { input, flow in
        try await dependencies.yield {
            let value = try bindings.input.decode(input)
            flow.state.startReadingServer(absent: bindings.inbound.absent)
            // With no inbound lane the complete request is INPUT, END, EOF.
            // Reject extra/truncated frames before entering application code.
            if bindings.inbound.absent { _ = try await flow.state.result.wait() }
            let stream = Tailcat.Stream(incoming: Tailcat.Incoming(codec: bindings.inbound, flow: flow), codec: bindings.yield, flow: flow)
            let output = try await handler(value, stream)
            flow.state.revoke()
            // Join/close cancels any reader stalled on unconsumed inbound messages.
            try await flow.state.terminal(output, codec: bindings.output)
        }
    }
}
