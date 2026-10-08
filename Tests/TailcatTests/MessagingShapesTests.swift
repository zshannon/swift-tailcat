import Foundation
import Tailcat
import Testing

private enum Shape0: Request {
    static let event = "shape0"
}
private enum Shape1: Request {
    typealias Inbound = Int
    static let event = "shape1"
}
private enum Shape2: Request {
    typealias Input = Int
    static let event = "shape2"
}
private enum Shape3: Request {
    typealias Inbound = Int
    typealias Input = Int
    static let event = "shape3"
}
private enum Shape4: Request {
    typealias Output = Int
    static let event = "shape4"
}
private enum Shape5: Request {
    typealias Inbound = Int
    typealias Output = Int
    static let event = "shape5"
}
private enum Shape6: Request {
    typealias Input = Int
    typealias Output = Int
    static let event = "shape6"
}
private enum Shape7: Request {
    typealias Inbound = Int
    typealias Input = Int
    typealias Output = Int
    static let event = "shape7"
}
private enum Shape8: Request {
    typealias Yield = Int
    static let event = "shape8"
}
private enum Shape9: Request {
    typealias Inbound = Int
    typealias Yield = Int
    static let event = "shape9"
}
private enum Shape10: Request {
    typealias Input = Int
    typealias Yield = Int
    static let event = "shape10"
}
private enum Shape11: Request {
    typealias Inbound = Int
    typealias Input = Int
    typealias Yield = Int
    static let event = "shape11"
}
private enum Shape12: Request {
    typealias Output = Int
    typealias Yield = Int
    static let event = "shape12"
}
private enum Shape13: Request {
    typealias Inbound = Int
    typealias Output = Int
    typealias Yield = Int
    static let event = "shape13"
}
private enum Shape14: Request {
    typealias Input = Int
    typealias Output = Int
    typealias Yield = Int
    static let event = "shape14"
}
private enum Shape15: Request {
    typealias Inbound = Int
    typealias Input = Int
    typealias Output = Int
    typealias Yield = Int
    static let event = "shape15"
}

@Suite struct MessagingShapesTests {
    @Test func allConcreteLaneShapesRegisterWithoutAuthorExtensions() {
        let registrations: [Tailcat.Handler] = [
            Handle(Shape0.self) { _, _ in () },
            Handle(Shape1.self) { _, _ in () },
            Handle(Shape2.self) { _, _ in () },
            Handle(Shape3.self) { _, _ in () },
            Handle(Shape4.self) { _, _ in 1 },
            Handle(Shape5.self) { _, _ in 1 },
            Handle(Shape6.self) { _, _ in 1 },
            Handle(Shape7.self) { _, _ in 1 },
            Handle(Shape8.self) { _, _ in () },
            Handle(Shape9.self) { _, _ in () },
            Handle(Shape10.self) { _, _ in () },
            Handle(Shape11.self) { _, _ in () },
            Handle(Shape12.self) { _, _ in 1 },
            Handle(Shape13.self) { _, _ in 1 },
            Handle(Shape14.self) { _, _ in 1 },
            Handle(Shape15.self) { _, _ in 1 },
        ]
        #expect(Set(registrations.map(\.event)).count == 16)
    }
}

// Compile the concrete open/call conveniences through a normal module import.
private func openShapes(_ connection: Tailcat.Connection) async throws {
    let s0 = try await connection.open(Shape0.self)
    await s0.resetAndWait()
    _ = try await connection.call(Shape0.self)
    let s1 = try await connection.open(Shape1.self)
    await s1.resetAndWait()
    let s2 = try await connection.open(Shape2.self, input: 1)
    await s2.resetAndWait()
    _ = try await connection.call(Shape2.self, input: 1)
    let s3 = try await connection.open(Shape3.self, input: 1)
    await s3.resetAndWait()
    let s4 = try await connection.open(Shape4.self)
    await s4.resetAndWait()
    _ = try await connection.call(Shape4.self)
    let s5 = try await connection.open(Shape5.self)
    await s5.resetAndWait()
    let s6 = try await connection.open(Shape6.self, input: 1)
    await s6.resetAndWait()
    _ = try await connection.call(Shape6.self, input: 1)
    let s7 = try await connection.open(Shape7.self, input: 1)
    await s7.resetAndWait()
    let s8 = try await connection.open(Shape8.self)
    await s8.resetAndWait()
    let s9 = try await connection.open(Shape9.self)
    await s9.resetAndWait()
    let s10 = try await connection.open(Shape10.self, input: 1)
    await s10.resetAndWait()
    let s11 = try await connection.open(Shape11.self, input: 1)
    await s11.resetAndWait()
    let s12 = try await connection.open(Shape12.self)
    await s12.resetAndWait()
    let s13 = try await connection.open(Shape13.self)
    await s13.resetAndWait()
    let s14 = try await connection.open(Shape14.self, input: 1)
    await s14.resetAndWait()
    let s15 = try await connection.open(Shape15.self, input: 1)
    await s15.resetAndWait()
}
