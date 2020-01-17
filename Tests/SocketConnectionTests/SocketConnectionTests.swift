import XCTest
@testable import SocketConnection

final class SocketConnectionTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(SocketConnection().text, "Hello, World!")
    }

    static var allTests = [
        ("testExample", testExample),
    ]
}
