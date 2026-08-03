import XCTest
@testable import MessagevisorCLI

final class MessagevisorCLITests: XCTestCase {
    func testReleaseVersion() {
        XCTAssertEqual(messagevisorSwiftVersion, "0.1.0")
    }

    func testRepeatedAndBooleanOptions() {
        let options = CLIOptions(["--target=ios", "--target", "watch", "--onlyFailures", "-n", "25"])
        XCTAssertEqual(options.value("target"), "watch")
        XCTAssertTrue(options.flag("onlyFailures"))
        XCTAssertEqual(options.value("n"), "25")
    }
}
