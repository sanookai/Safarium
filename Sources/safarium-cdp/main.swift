import AppKit
import Foundation
import SafariumCore

// safarium-cdp: a "fake Chrome" that speaks the Chrome DevTools Protocol subset used by puppeteer-core 25.x and
// HyperFrames over --remote-debugging-pipe (fd 3 = client to us, fd 4 = us to client), backed by SafariumCore.

let shimVersion = "0.1.0"
let versionBanner = "Safarium CDP shim \(shimVersion) (WebKit)"

struct Options {
    var width = 800
    var height = 600
    var pipe = false
}

func parseOptions(_ args: [String]) -> Options {
    var o = Options()
    for a in args {
        if a == "--remote-debugging-pipe" { o.pipe = true }
        if a.hasPrefix("--window-size=") {
            let parts = a.dropFirst("--window-size=".count).split(separator: ",").compactMap { Int($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { o.width = parts[0]; o.height = parts[1] }
        }
    }
    return o
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") {
    print(versionBanner)
    exit(0)
}
let options = parseOptions(arguments)
guard options.pipe else {
    FileHandle.standardError.write(Data("safarium-cdp: only --remote-debugging-pipe is supported (use --version to print the version)\n".utf8))
    exit(2)
}

setvbuf(stdout, nil, _IOLBF, 0)
let transport = PipeTransport(readFd: 3, writeFd: 4)
var server: Server!
Task { @MainActor in
    HostApp.prepare()
    server = Server(transport: transport, options: options)
    transport.start { msg in
        MainActor.assumeIsolated { server.receive(msg) }
    }
}
NSApplication.shared.run()
