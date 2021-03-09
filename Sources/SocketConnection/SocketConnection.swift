//
//  SocketConnection.swift
//
//  Created by Grant Grueninger on 9/5/19.
//  Copyright © 2019 Grant Grueninger. All rights reserved.
//

import Foundation
import Combine

/// Manages a two-way socket connection to a server (e.g. an IMAP server).
///
///     let connection = SocketConnection()
///
///     // Subscribe to incoming data
///     let dataSubscriber = connection?.receivedData.sink(receiveValue: { data in
///         let stringReceived = String(decoding: data, as: UTF8.self)
///         if stringReceived.contains("* OK ") {
///             print("Server says OK")
///         }
///     })
///
///     // Subscribe to status notifications
///     let statusSubscriber = connection.connectionStatus.sink(receivedValue: { status in
///         switch status {
///             case .openCompleted:
///                 self.startLogin()
///                 self.isConnected = true // But also see SocketConnection.connected
///             case .errorOccurred(let error):
///                 // e.g. if you have a connection indicator
///                 self.isConnected = false
///                 // e.g. if your SwiftUI view has a place to display errors
///                 self.errorMessage = "Error with connection to server: \(error.localizedDescription)"
///                 print("Something broke: \(error.localizedDescription)")
///             case .endEncountered:
///                 self.isConnected = false
///                 print("This is the end; the end, my friend.")
///         })
///
///     // Let's say you have a network status indicator triggered by setting
///     // "self.readingFromServer". Automatically update it by subscribing to
///     // readingFromNetwork.
///     let activitySubscriber = connection.readingFromNetwork
///         .throttle(for: 1.0, scheduler: RunLoop.current, latest: true) // Ignore really fast on/off
///         .sink(receivedValue: {
///             self.readingFromServer = $0
///         })
///
///     // Connect
///     connection.connect(host: "imap.gmail.com", port: 993, useSSL: true)
///
///     // Say hi
///     connection.write("A001 LOGIN SMITH SESAME\r\n")
///
/// Call `write` to write (strings or raw data) to the server.
///
/// Subscribe to:
/// - `receivedData` to read data from the server
/// - `connectionStatus` to get status updates about the connection
/// - `readingFromNetwork` to get a true/false signal that the connection's reading from the network
///
@available(iOS 13.0, OSX 10.15, tvOS 13.0, *)
public class SocketConnection: NSObject, StreamDelegate {

    /// An error involving the socket connection or reading/writing data
    public enum ConnectionError: Error {
        /// The provided string couldn't be converted to a Data object.
        case unableToConvertStringToData(String)

        /// The `write` method tried to get a pointer for the start of the data, but was unable to get the base address of the data
        ///
        /// That is, something's wrong with the data, or something happened to the computer's memory that caused something to be wrong with the data.
        case unableToConvertDataForWrite

        /// The write to the stream failed. "withError" will contain the localized string from the stream's error message.
        case writeToStreamFailed(withError: String)

        /// SocketConnection was unable to open or maintain the input or output stream.
        case unableToConnect
    }

    /// A status that can be sent via the `connectionStatus` publisher. These mirror the Stream.Event constants that Stream will send to its
    /// delegate (this class), that we process in `stream(_ sender: Stream, handle streamEvent: Stream.Event)`.
    /// `stream` receives the events from `InputStream` and `OutputStream`, reacts to those it can (e.g. by reading or writing data)
    /// and fowards the events in this enum on through the `connectionStatus` publisher.
    public enum Status {
        /// Initial connection established with _both_ the input and output streams.
        case openCompleted

        /// An error occurred - connection terminated. `error` will contain the error from `Stream`.
        ///
        /// Note that this doesn't necessarily happen only during the initial connection - an error could happen at any time.
        /// When an error does occur, `SocketConnection` shuts down both streams (regardless of whether or not one is still functional),
        /// clears any data queued for writing, and sends `SocketConnection.Status.errorOccurred(Error)` through
        /// `connectionStatus`.
        case errorOccurred(Error?)

        /// The end of the stream has been reached.
        ///
        /// This usually means the server closed the connection.
        case endEncountered
    }

    /// The input side of the connection
    var inputStream: InputStream?

    /// The output side of the connection
    var outputStream: OutputStream?

    /// A Combine Publisher to which all data received will be sent
    ///
    /// This is how you receive data from the connection. Subscribe to `receivedData` and handle the incoming data in your callback.
    /// This means you can also use any of the Publisher methods on the received data - e.g. "decode".
    ///
    /// Boring example:
    ///
    ///     let subscriber = connection?.receivedData.sink(receiveValue: { data in
    ///         let stringReceived = String(decoding: data, as: UTF8.self)
    ///         if stringReceived.contains("* OK ") {
    ///             print("Server says OK")
    ///         }
    ///     })
    ///
    /// The example is boring because you could do something like:
    ///
    ///     let subscriber = connection?.receivedData
    ///         // Check the incoming data, make sure it's MyType, delegate handling of "OK", status messages,
    ///         // etc, throw if it's not "MyType" (you could also use "map" instead of "tryMap" and return
    ///         // "false" from `self.parseAndCleanup` I suppose - I just like throwing things).
    ///         .tryMap({ self.parseAndCleanup($0) })
    ///         // Convert to a MyType object.
    ///         .decoder(type: MyType.self, decoder: MyDecoder())
    ///         // Store your decoded MyType object in the DB, display to user, etc.
    ///         .sink(receiveValue: { myType in
    ///             // Do something with your decoded object
    ///         })
    public let receivedData = PassthroughSubject<Data,Never>()

    /// A Publisher that sends connection status updates
    ///
    /// Consumers of `SocketConnection` can subscribe to be notified of connection status changes via `connectionStatus`.
    ///
    /// Example:
    ///
    ///     let connection = SocketConnection()
    ///     // Set this up before connecting so you get all the notifications
    ///     // Note that you _must_ retain the return value or your callback will never get called.
    ///     let statusSubscriber = connection.connectionStatus.sink(receivedValue: { status in
    ///         switch status {
    ///             case .openCompleted:
    ///                 print("We've made contact!")
    ///                 // You might also, say, call a login method here, or whatever you want to do with the server
    ///                 // now that you're connected. The event is sent when the output stream is connected (meaning
    ///                 // both the input and output streams have been connected, so you can start using the
    ///                 // connection).
    ///             case .errorOccurred(let error):
    ///                 // One of the streams (input or output) reported an error. The error the stream reported is
    ///                 // passed as an Error object, which can be `nil` if the stream passed the event without
    ///                 // setting the error (which "shouldn't" happen, but theoretically could).
    ///                 print("Something broke: \(error?.localizedDescription ?? "Not sure what though")")
    ///             case .endEncountered:
    ///                 print("This is the end; the end, my friend.")
    ///         })
    ///     connection.connect(to: "localhost", on: 143, usingSSL: false)
    ///
    /// More practical example:
    ///
    ///     let connection = SocketConnection()
    ///     let statusSubscriber = connection.connectionStatus.sink(receivedValue: { status in
    ///         switch status {
    ///             case .openCompleted:
    ///                 self.startLogin()
    ///                 self.isConnected = true // But also see SocketConnection.connected
    ///             case .errorOccurred(let error):
    ///                 // e.g. if you have a connection indicator
    ///                 self.isConnected = false
    ///                 // e.g. if your SwiftUI view has a place to display errors
    ///                 self.errorMessage = "Error with connection to server: \(error.localizedDescription)"
    ///                 print("Something broke: \(error.localizedDescription)")
    ///             case .endEncountered:
    ///                 self.isConnected = false
    ///                 print("This is the end; the end, my friend.")
    ///         })
    ///     connection.connect(to: "localhost", on: 143, usingSSL: false)
    public let connectionStatus = PassthroughSubject<Status, Never>()

    /// Sends "true" when we're actively reading from the connection, "false" if we were reading but finished.
    ///
    /// You can use this to set a network activity indicator in your UI, e.g. for downloading a big attachment:
    ///
    ///     let activitySubscriber = connection.readingFromNetwork
    ///         .throttle(for: 1.0, scheduler: RunLoop.current, latest: true) // Ignore really fast on/off
    ///         .sink(receivedValue: {
    ///             self.readingFromServer = $0
    ///         })
    public let readingFromNetwork = PassthroughSubject<Bool, Never>()

    /// Flag to indicate that `connect` is attempting to establish a connection
    ///
    /// This is used by the `connecting` computed variable, along with the status of `inputStream` and `outputStream` to determine
    /// whether we're in the process of connecting or not.
    private var isConnecting: Bool = false

    /// A queue of data to write when the output socket has space available
    ///
    /// See the `stream` delegate function and `write` methods. When `write` is called, it queues up the data it's given in `writeQueue`.
    /// When `stream` receives the `hasSpaceAvailable` event, it writes out what's in writeQueue in the order received.
    private var writeQueue = [Data]()

    /// A flag that indicates whether or not all the data in writeQueue has been written
    ///
    /// This is set by `write` when it writes data to the output stream, and cleared when the `hasSpaceAvailable` event is received by
    /// `stream`. When `hasSpaceAvailable` is received, `stream` writes and removes the first element in `writeQueue`.
    /// Then `hasSpaceAvailable` is received agian, and `stream` writes/removes the next element, and so on until it receives `hasSpaceAvailable`
    /// and `writeQueue` is empty, at which point it sets `passedWrite` to true, which signals the `write` method that it can write again without
    /// waiting for `hasSpaceAvailable` (because we were already told we had space available).
    private var passedWrite: Bool = false

    /// Connects to the specified TCP host on the specified port, optionally using SSL.
    ///
    /// - Parameter host: A string identifying the host to connect to, e.g. an IP address or domain name: "192.168.0.1", "imap.gmail.com", "localhost", etc.
    /// - Parameter port: The port to connect to, e.g. 80 for HTTP, 143 for IMAP, 993 for IMAP SSL
    /// - Parameter usingSSL: `true` to negotiate an SSL connection, `false` otherwise. Use `false` for testing (e.g. connecting to `localhost`,
    ///     `true` when connecting to a real server (e.g. `imap.gmail.com`). `connect` isn't smart enough to tell if you specify a non-SSL port and
    ///     say `true` for `usingSSL` - your connection will just fail and you'll get an error sent via `connectionStatus`.
    public func connect(to host: String, on port: Int, usingSSL: Bool) {

        isConnecting = true

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault,
                                           host as CFString,
                                           UInt32(port),
                                           &readStream,
                                           &writeStream)

        inputStream = readStream!.takeRetainedValue()
        outputStream = writeStream!.takeRetainedValue()

        if let inputStream = inputStream, let outputStream = outputStream {
            inputStream.delegate = self
            outputStream.delegate = self

            inputStream.schedule(in: .current, forMode: .common)
            outputStream.schedule(in: .current, forMode: .common)

            inputStream.open()
            outputStream.open()

            if usingSSL {
                inputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: Stream.PropertyKey.socketSecurityLevelKey)
                outputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: Stream.PropertyKey.socketSecurityLevelKey)
            }
        } else {
            SocketConnection.log("inputStream or outputStream was nil.")
        }

        isConnecting = false

    }

    /// No R2, shut them all down! (Closes the input and output streams)
    public func close() {
        inputStream?.close()
        inputStream?.remove(from: .current, forMode: .common)
        inputStream = nil

        outputStream?.close()
        outputStream?.remove(from: .current, forMode: .common)
        outputStream = nil
    }

    /// Writes `data` to the connection, queueing as needed.
    ///
    /// - Throws: ConnectionError.unableToConvertDataForWrite, ConnectionError.writeToStreamFailed(withError: String)
    public func write(_ data: Data) throws {
        if connected && passedWrite && outputStream != nil {
            try write(data: data, to: outputStream!)
            passedWrite = false
        } else {
            writeQueue.append(data)
        }
    }

    /// Writes the `string` to the active connection
    ///
    /// Example:
    ///     imap.write("a001 LOGIN SMITH SESAME\n")
    ///
    /// You won't usually use this command yourself, unless you need to send something specific directly to the IMAP server. This method is used
    /// internally to send messages to the server.
    ///
    /// - Parameter string: The string to write to the IMAP server. This is converted into a Data object.
    /// - Throws: ConnectionError.unableToConvertStringToData
    public func write(_ string: String) throws {
        if let data = string.data(using: .utf8) {
            try write(data)
        } else {
            throw ConnectionError.unableToConvertStringToData(string)
        }
    }

    /// Writes the contents of `data` to the specified output stream
    ///
    /// This is mainly because writing data to a socket in Swift is ugly, so with this method I can do "write(data: someData, to: someStream" instead.
    ///
    /// - Parameters:
    ///   - data: The Data to write to the stream
    ///   - stream: The stream to write to - this will almost always be self.outputStream
    ///
    /// - Throws: ConnectionError.unableToConvertDataForWrite, ConnectionError.writeToStreamFailed(withError: String)
    func write(data: Data, to stream: OutputStream) throws {
        _ = try data.withUnsafeBytes {
            guard let pointer = $0.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw ConnectionError.unableToConvertDataForWrite
            }
            let bytesWritten = stream.write(pointer, maxLength: data.count)
            if bytesWritten > 0 {
                return
            } else if bytesWritten == 0 {
                // Output channel has no more room, queue the data up to write later
                writeQueue.append(data)
            } else {
                throw ConnectionError.writeToStreamFailed(withError: stream.streamError?.localizedDescription
                    ?? "Stream error undefined")
            }
        }
    }

    /// True if we're connected to the server
    ///
    /// You'll usually want to check `if !connection.connected && !connection.connecting` before trying to connect.
    public var connected: Bool {
        let istat = inputStream?.streamStatus
        let ostat = outputStream?.streamStatus
        let connected = istat != .notOpen && istat != .opening && istat != .closed && istat != .error &&
            ostat != .notOpen && ostat != .opening && ostat != .closed && ostat != .error &&
            inputStream != nil && outputStream != nil

        return connected
    }

    /// True if we're in the process of connecting to the server
    public var connecting: Bool {
        let istat = inputStream?.streamStatus
        let ostat = outputStream?.streamStatus

        return isConnecting || istat == .opening || ostat == .opening
    }


    // NSStreamDelegate
    public func stream(_ sender: Stream, handle streamEvent: Stream.Event) {
        switch streamEvent {
        case .openCompleted:
            if sender == outputStream {
                connectionStatus.send(.openCompleted)
            }
        case .hasBytesAvailable:
            SocketConnection.log("new message received")
            if let stream = sender as? InputStream {
                readAvailableBytes(stream: stream)
            }
            break;
        case .hasSpaceAvailable:
            if sender == inputStream {
                SocketConnection.log("input has space available")
                // I don't think sender == InputStream and .hasSpaceAvailable can happen, but if it does, ignore it.
                break;
            }

            if sender == outputStream {
                SocketConnection.log("output has space available")
            }

            // See if we've got something in the queue to write. If so, send it.
            if !writeQueue.isEmpty {
                if let stream = sender as? OutputStream, let data = writeQueue.first {
                    do {
                        SocketConnection.log("  - writing queued data to stream")
                        try write(data: data, to: stream)
                        writeQueue.removeFirst()
                    } catch {
                        SocketConnection.log("Caught thrown error while writing data: \(error)")
                        // Add handling code based on encountered scenarios. Do we need to reconnect?
                        // Do we need to reject or reformat the data?
                        // As of 1/15/20 the only reason for `write` to `throw` is if the data we sent
                        // is "bad" (`$0.baseAddress?.assumingMemoryBound(to: UInt8.self)` returns `nil`),
                        // or the write to the stream fails (e.g. the connection dropped).

                        // For now, clear the queue and report the error.
                        writeQueue.removeAll()
                        connectionStatus.send(.errorOccurred(error))
                    }
                } else {
                    let error = "Have stuff to write, but either didn't get an OutputStream or something other than "
                        + "Data was in the queue."
                    SocketConnection.log(error)
                    writeQueue.removeAll()
                    connectionStatus.send(.errorOccurred(ConnectionError.writeToStreamFailed(withError: error)))
                }
            } else {
                passedWrite = true;
            }
            break;
        case .errorOccurred:
            SocketConnection.log("error occurred")
            writeQueue.removeAll()
            connectionStatus.send(.errorOccurred(sender.streamError))
            break;

        case .endEncountered:
            SocketConnection.log("End of stream reached")
            if sender == inputStream {
                SocketConnection.log("    - Input stream")
            }
            if sender == outputStream {
                SocketConnection.log("    - Output stream")
            }

            // Are these the right actions to take? What does "end of stream" mean - stream's closed, or it just
            // doesn't have more data to send?
            writeQueue.removeAll()
            connectionStatus.send(.endEncountered)
            close()
            break;

        default:
            // Stream.Event is a struct with constants, not an enum, so we have to have a "default" condition
            // for the switch. `stream` can't `throw` because it's a delegate method, so we just print
            // a quiet log entry that nobody will see unless they're really looking.
            SocketConnection.log("A Stream.Event was sent that doesn't exist as of MacOS 10.15.2 / iOS 13.3...")
        }
    }

    /// Reads (all) the available bytes from `stream` and sends them to `delegate?.got(data:)`
    ///
    /// This is designed to read a message from an IMAP server, and as such expects a finite response. But, theoretically, this could slurp
    /// infinitely. Might want to add a control of some sort (e.g. a single read with a real maxReadLength instead of a loop).
    private func readAvailableBytes(stream: InputStream) {
        readingFromNetwork.send(true)
        let maxReadLength = 1024
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxReadLength)
        while stream.hasBytesAvailable {

            let numberOfBytesRead = stream.read(buffer, maxLength: maxReadLength)
            if numberOfBytesRead > 0 {
                data.append(buffer, count: numberOfBytesRead)
            }

            if numberOfBytesRead < 0, let error = stream.streamError {
                SocketConnection.log(error.localizedDescription)
                break
            }

        }

        // Maybe put this in the loop above?
        receivedData.send(data as Data)

        readingFromNetwork.send(false)
    }

    /// Prints `message` with a filterable `[IMAP]` prefix if running in DEBUG mode
    public static func log(_ message: String) {
        #if DEBUG
        let timeString = SocketConnection.logDateFormatter.string(from: Date())
        let splitMessage: [String] = message.components(separatedBy: .newlines)
        for line in splitMessage {
            if line.isEmpty { continue }
            print("\(timeString) [SocketConnection]: \(line)")
        }
        #endif
    }

    /// The date/time format used for log output
    static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

