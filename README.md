# SocketConnection

A pure Swift package for establishing a two-way socket connection to a server that uses
Combine, rather than delegates, to send data and notifications back to your code.

This makes it great for modern apps using SwiftUI, but also means it (currently) doesn't work on
Linux. 😔🐧

Requires iOS/iPadOS/tvOS 13.0+, or MacOS 10.15.0+. Does _not_ run on WatchOS (including 6.0+).

     let connection = SocketConnection()

     // Subscribe to incoming data
     let dataSubscriber = connection?.receivedData.sink(receiveValue: { data in
         let stringReceived = String(decoding: data, as: UTF8.self)
         if stringReceived.contains("* OK ") {
             print("Server says OK")
         }
     })

     // Subscribe to status notifications
     let statusSubscriber = connection.connectionStatus.sink(receivedValue: { status in
         switch status {
             case .openCompleted:
                 self.startLogin()
                 self.isConnected = true // But also see SocketConnection.connected
             case .errorOccurred(let error):
                 // e.g. if you have a connection indicator
                 self.isConnected = false
                 // e.g. if your SwiftUI view has a place to display errors
                 self.errorMessage = "Error with connection to server: \(error.localizedDescription)"
                 print("Something broke: \(error.localizedDescription)")
             case .endEncountered:
                 self.isConnected = false
                 print("This is the end; the end, my friend.")
         })

     // Let's say you have a network status indicator triggered by setting
     // "self.readingFromServer". Automatically update it by subscribing to
     // readingFromNetwork.
     let activitySubscriber = connection.readingFromNetwork
         .throttle(for: 1.0, scheduler: RunLoop.current, latest: true) // Ignore really fast on/off
         .sink(receivedValue: {
             self.readingFromServer = $0
         })

     // Connect
     connection.connect(host: "imap.google.com", port: 993, useSSL: true)

     // Say hi
     connection.write("A001 LOGIN SMITH SESAME\n")

 Call `write` to write commands to the server.

 Subscribe to:
 - `receivedData` to read data from the server
 - `connectionStatus` to get status updates about the connection
 - `readingFromNetwork` to get a true/false signal that the connection's reading from the network

## Installation

SocketConnection is a swift package - add it to `Package.swift`:

    dependencies: [
        .package(url: "https://github.com/ggruen/SocketConnection.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: ["SocketConnection"]),
    ]
