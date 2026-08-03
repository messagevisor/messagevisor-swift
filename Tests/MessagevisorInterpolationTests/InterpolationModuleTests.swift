import XCTest
import Messagevisor
@testable import MessagevisorInterpolation

final class InterpolationModuleTests: XCTestCase {
    func testInterpolatesPrimitiveValues() throws {
        let sdk = createMessagevisor(.init(locale: "en", modules: [createInterpolationModule()]))
        XCTAssertEqual(try sdk.formatMessage("Hello, {name}!", values: ["name": .string("Ada")]), "Hello, Ada!")
        XCTAssertEqual(try sdk.formatMessage("{count} {enabled} {missing} {object}", values: ["count": .int(2), "enabled": .bool(true), "object": .object(["x": .int(1)])]), "2 true {missing} {object}")
    }
}
