Development Notes
===============

Handy SPM commands you forget
----------------------------------------

Create Tests/Linuxmain.swift - run after making any changes to tests (in case Combine comes to Linux):

    # Regenerate list of tests for Linux (regenerates XCTestManifests and
    # LinuxMain.swift, both in the Tests folder). Build in /tmp because we don't need
    # the build artifacts and I don't like cluttering up my development folder.
    swift test --generate-linuxmain --build-path="/tmp"

Build in a different folder:

    swift build --build-path="$HOME/Downloads/.build"

How to run the tests
-----------------------

To run tests, you need to set "host" and "port" in "SocketConnectionTests".
Rather than hammering your personal email account, I recommend installing
a local IMAP server, like [imap-server](https://www.npmjs.com/package/imap-server)

First, `cd` to wherever you want to put the server code. Can be temporary
like /tmp or ~/Downloads. Then, install `imap-server`

    mkdir imap-test-server
    cd imap-test-server
    npm install imap-server

In your imap-test-server directory, Put this script into `imap-test-server.js`:

    var ImapServer = require('imap-server');
    var server = ImapServer();

    // use plugin
    var plugins = require('imap-server/plugins');
    server.use(plugins.announce);
    /* use more builtin or custom plugins... */

    var net = require('net');
    net.createServer(server).listen(process.env.IMAP_PORT || 143);

Then you can run your test server, which will run on localhost:143:

    node imap-test-server.js

How to generate API docs
------------------------------

Requires Jazzy: `[sudo] gem install jazzy`

    jazzy \
      --module Swiftimap \
      --swift-build-tool spm \
      --build-tool-arguments -Xswiftc,-swift-version,-Xswiftc,5 \
      --output ~/Downloads/swiftimap_docs
