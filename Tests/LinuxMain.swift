import XCTest

import SocketConnectionTests

var tests = [XCTestCaseEntry]()
tests += SocketConnectionTests.__allTests()

XCTMain(tests)
