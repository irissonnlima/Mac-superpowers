import Foundation
import XCTest
@testable import MacSuperpowers

final class SystemTrashPolicyTests: XCTestCase {
    func testOnlyAllowsScannedLibraryAreasAndRejectsSymlinks() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: root) }
        let home = root.appending(path: "Home")
        let system = root.appending(path: "SystemLibrary")
        let allowed = system.appending(path: "LaunchDaemons/com.example.helper.plist")
        let outside = root.appending(path: "Other/private.txt")
        let link = system.appending(path: "LaunchDaemons/com.example.link.plist")
        try manager.createDirectory(at: allowed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: allowed)
        try Data([2]).write(to: outside)
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)

        let policy = SystemTrashPolicy(homeURL: home, systemLibraryURL: system)
        XCTAssertTrue(policy.allows(allowed))
        XCTAssertFalse(policy.allows(system.appending(path: "LaunchDaemons")))
        XCTAssertFalse(policy.allows(outside))
        XCTAssertFalse(policy.allows(link))
        XCTAssertFalse(policy.allows(system.appending(path: "LaunchDaemons/bad\nname.plist")))
    }
}
