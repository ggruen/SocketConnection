import XCTest

import SocketConnectionTests

var tests = [XCTestCaseEntry]()
tests += SocketConnectionTests.allTests()
XCTMain(tests)
