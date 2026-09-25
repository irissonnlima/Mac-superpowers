import Foundation
import XCTest
@testable import MacSuperpowers

final class PrivilegedTrashTests: XCTestCase {
    func testShellQuotePreservesPathsWithoutExecutingShellContent() throws {
        let path = "/Library/LaunchDaemons/name' ; $(printf injected).plist"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/usr/bin/printf %s \(PrivilegedTrash.shellQuote(path))"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), path)
    }

    func testAppleScriptQuoteEscapesQuotesAndBackslashes() {
        XCTAssertEqual(PrivilegedTrash.appleScriptQuote("a\\b\"c"), "\"a\\\\b\\\"c\"")
    }
}
