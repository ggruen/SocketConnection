//
//  SocketConnectionTests.swift
//  Swiftimap
//
//  Created by Grant Grueninger on 10/28/19.
//

import XCTest
@testable import SocketConnection

@available(tvOS 13.0, *)
@available(OSX 10.15, *)
@available(iOS 13.0, *)
final class SocketConnectionTests: XCTestCase {
    var connection: SocketConnection?

    /// Host to use for testing. You can change this to any IMAP server. The tests just connect and send commands that don't need authentication.
    ///
    /// Note: https://www.npmjs.com/package/imap-server
    /// See Development.md to set up a quick test server.
    let host = "localhost"

    /// Port on the host to use for testing.
    let port = 143

    override func setUp() {
        // Given a valid server host and port (host and port are set at the class level above)

        // When connect is called
        connection = SocketConnection()
        let connectedExpectation = XCTestExpectation(description: "Publisher sent OK")
        // holding the subscriber instance is required or the subscription is immediately lost
        let dataReceiver = connection?.receivedData.sink(receiveValue: { data in
            let stringReceived = String(decoding: data, as: UTF8.self)
            if stringReceived.contains("* OK ") {
                connectedExpectation.fulfill()
            }
        })
        let connectionOpenExpectation = XCTestExpectation(description: "SocketConnection reported connection open")
        let statusUpdates = connection?.connectionStatus.sink(receiveValue: { status in
            switch status {
            case .openCompleted:
                connectionOpenExpectation.fulfill()
            default:
                // Got an unexpected status
                XCTFail("Got unexpected status during connection")
            }
        })
        connection?.connect(to: host, on: port, usingSSL: port == 993)
        // Make sure the connection is open and the server has responded before making any more requests
        wait(for: [connectionOpenExpectation, connectedExpectation], timeout: 2.0)

        dataReceiver?.cancel() // We're about to deallocate anyway
        statusUpdates?.cancel()

        // Fun fact about combine: at this point we're not listening to incoming data any more.
        // If the server says something, we won't hear it.

    }

    func testCanConnectToImapServer() {
        // Given a valid server host and port
        // When connect is called

        // Then connection to the server is established
        XCTAssertTrue(connection?.connected ?? false)
        XCTAssertNotNil(connection?.inputStream)
        XCTAssertNotNil(connection?.outputStream)
    }

    func testCanReadFromServer() {

        // Given a connection to the server
        // When the connection is established
        // Then data is received from the server

        // This whole test is now done in setUp - using Combine instead of a delegate obsoleted a ton of code.
        // Keeping this test as it'll still fail if setUp fails, and we do need to test that we can read from the
        // server.
    }

    func testReadingFromNetworkIndicatorChangesOnRead() throws {
        // Given a subscription to "readingFromNetwork"
        let activityExpectation = XCTestExpectation(description: "Reading from network flag sent")
        let activityDoneExpectation = XCTestExpectation(description: "Reading from network false flag sent")
        let activitySubscription = connection?.readingFromNetwork.sink(receiveValue: {
            switch $0 {
            case true:
                activityExpectation.fulfill()
            case false:
                activityDoneExpectation.fulfill()
            }
        })

        // When data is sent by the server
        try connection?.write("A003 NOOP\r\n")

        // Then "readingFromNetwork" sends "true" ...
        // ... and then "false"
        wait(for: [activityExpectation, activityDoneExpectation], timeout: 2.0)

        activitySubscription?.cancel()
    }

    func testCanWriteToServer() throws {
        // Given a connection to the server
        XCTAssert(connection?.connected ?? false)

        // When a NOOP command is written
        let connectionReceivedDataExpectation = XCTestExpectation(description:
            "Received response to NOOP")
        let dataReceiver = connection?.receivedData.sink(receiveValue: { data in
            XCTAssertGreaterThan(data.count, 0)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("A001"))
            connectionReceivedDataExpectation.fulfill()
        })
        try connection?.write("A001 NOOP\r\n")

        // Then a response is received
        wait(for: [connectionReceivedDataExpectation], timeout: 2.0)

        dataReceiver?.cancel()
    }

    func testCanDetectDisconnectFromServer() throws {
        // Given a connection to the server
        XCTAssert(connection?.connected ?? false)

        // When a LOGOUT command is sent
        // (we set up the expectations first, then send the command)

        // Then the server receives data
        let connectionReceivedDataExpectation = XCTestExpectation(description:
            "Received response to LOGOUT")

        // and we receive BYE
        let byeExpectation = XCTestExpectation(description:
            "Server said BYE")

        // and the server responds to our logout command
        let serverSaidOkToLogoutExpectation = XCTestExpectation(description:
            "Server said A002 OK in reply to A002 LOGOUT")

        // and the server closes the connection
        let serverClosedConnectionExpectation = XCTestExpectation(description: "Server closed the connection")

        // This is run when we receive data
        let dataReceiver = connection?.receivedData.sink(receiveValue: { data in
            // - We got data - satisfy that expectation
            connectionReceivedDataExpectation.fulfill()

            // - Now parse our data for expected responses
            let receivedString = String(decoding: data, as: UTF8.self)
            print(String(decoding: data, as: UTF8.self))

            // - Fulfill the BYE expectation
            if receivedString.contains(" BYE ") {
                print("Server said bye")
                byeExpectation.fulfill()
            }

            // - Fulfill the "OK to logout" expectation
            if receivedString.contains("A002 OK") {
                print("Server said OK to A002 logout")
                serverSaidOkToLogoutExpectation.fulfill()
            }
        })

        // We get status updates (which tell us if the server dropped the connection, for example) from
        // the "connectionStatus" publisher, so hook that up.
        let statusUpdates = connection?.connectionStatus.sink(receiveValue: { status in
            switch status {
            case .endEncountered:
                // - endEncountered means the remote server hung up on us, so fulfill that.
                serverClosedConnectionExpectation.fulfill()
            default:
                XCTFail("Got an unexpected status while waiting for server to close connection.")
            }
        })

        // Now we send our logout from the "when" above
        try connection?.write("A002 LOGOUT\r\n")

        // And wait for all our expectations to be fulfilled.

        // Note: On a remote connection, e.g. gmail.com, our logout can get queued up to send before the OK
        // from the connection is received - SocketConnection will send our "LOGOUT" when it gets the all clear
        // from the server (via .hasSpaceAvailable in `stream(_ aStream: Stream, handle eventCode: Stream.Event)`).

        // Also note: Node's `imap-server` doesn't disconnect after a LOGOUT, and has an idle timeout of 30 seconds,
        // so we wait 40 seconds. If you aim "host" at a real IMAP server, it will will disconnect instead of timing
        // out.
        wait(for: [connectionReceivedDataExpectation, byeExpectation, serverSaidOkToLogoutExpectation,
                   serverClosedConnectionExpectation], timeout: 40.0)

        XCTAssertFalse(connection?.connected ?? false)

        // Clean up
        dataReceiver?.cancel()
        statusUpdates?.cancel()
    }

    func testCanReconnectToServer() throws {
        // Given an active server connection (already established in setUp)
        XCTAssert(connection!.connected)

        // If I disconnect, then reconnect
        try connection!.write("A002 LOGOUT\r\n")
        connection!.close()
        XCTAssertFalse(connection!.connected)

        let connectedExpectation = XCTestExpectation(description: "Publisher sent OK")
        // holding the subscriber instance is required or the subscription is immediately lost
        let dataReceiver = connection?.receivedData.sink(receiveValue: { data in
            let stringReceived = String(decoding: data, as: UTF8.self)
            if stringReceived.contains("* OK ") {
                connectedExpectation.fulfill()
            }
        })
        let connectionOpenExpectation = XCTestExpectation(description: "SocketConnection reported connection open")
        let statusUpdates = connection?.connectionStatus.sink(receiveValue: { status in
            switch status {
            case .openCompleted:
                connectionOpenExpectation.fulfill()
            default:
                // Got an unexpected status
                XCTFail("Got unexpected status during connection")
            }
        })

        connection?.connect(to: host, on: port, usingSSL: port == 993)

        // Then I can write data to and read data from the connection
        wait(for: [connectionOpenExpectation, connectedExpectation], timeout: 3.0)

        // Clean up - Mostly to stop Xcode from complaining that these "aren't used".
        dataReceiver?.cancel()
        statusUpdates?.cancel()
    }

    override func tearDown() {
        connection?.close()
        connection = nil
    }

}
