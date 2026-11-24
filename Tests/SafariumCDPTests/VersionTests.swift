import XCTest

/// Runs the built `safarium-cdp` executable (the same binary HyperFrames/puppeteer launch) as a child process.
final class VersionTests: XCTestCase {
    func executableURL() -> URL {
        let products = Bundle(for: VersionTests.self).bundleURL.deletingLastPathComponent()
        return products.appendingPathComponent("safarium-cdp")
    }

    func testVersionPrintsVersionAndExitsZero() throws {
        let p = Process()
        p.executableURL = executableURL()
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotNil(text.range(of: #"\d+\.\d+"#, options: .regularExpression), text)
    }

    func testRefusesToRunWithoutPipeFlag() throws {
        let p = Process()
        p.executableURL = executableURL()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 2)
    }
}
