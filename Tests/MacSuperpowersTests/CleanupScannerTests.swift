import Foundation
import XCTest
@testable import MacSuperpowers

final class CleanupScannerTests: XCTestCase {
    func testSeparatesInstalledAppsFromPossibleLeftovers() throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: home) }
        let apps = home.appending(path: "Applications", directoryHint: .isDirectory)
        let installedApp = apps.appending(path: "Present.app", directoryHint: .isDirectory)
        let contents = installedApp.appending(path: "Contents", directoryHint: .isDirectory)
        try manager.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.present", "CFBundleName": "Present"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))

        try createFile("Library/Caches/com.example.present/cache.bin", under: home)
        try createFile("Library/Containers/com.example.present/data.bin", under: home)
        try createFile("Library/Containers/com.example.gone/data.bin", under: home)
        try createFile("Library/Containers/org.orphan.gone/data.bin", under: home)
        try createFile("Library/Containers/net.registered.remote/data.bin", under: home)
        try createFile("Library/Containers/group.com.apple.mail/data.bin", under: home)
        try createFile("Library/Containers/org.sparkle-project.DownloaderService/data.bin", under: home)
        try createFile("Library/Application Support/Present/data.bin", under: home)
        try createFile("Library/Application Support/Gone/data.bin", under: home)
        try createFile("Library/Caches/org.orphan.gone/cache.bin", under: home)
        try createFile("Library/Caches/Homebrew/cache.bin", under: home)
        try createFile("Library/Caches/com.apple.system/cache.bin", under: home)

        let report = CleanupScanner(
            homeURL: home,
            systemLibraryURL: home.appending(path: "SystemLibrary"),
            registeredApp: { $0 == "net.registered.remote" }
        ).scan()
        let names = Set(report.candidates.map(\.name))
        XCTAssertTrue(names.contains("org.orphan.gone"))
        XCTAssertFalse(names.contains("com.example.present"))
        XCTAssertFalse(names.contains("com.example.gone"), "Shared vendor data is ambiguous")
        XCTAssertFalse(names.contains("net.registered.remote"))
        XCTAssertFalse(names.contains("Gone"), "Generic support folder names are insufficient evidence")
        XCTAssertFalse(names.contains("Present"))
        XCTAssertFalse(names.contains("Homebrew"))
        XCTAssertFalse(names.contains("com.apple.system"))
        XCTAssertFalse(names.contains("group.com.apple.mail"))
        XCTAssertFalse(names.contains("org.sparkle-project.DownloaderService"))
        XCTAssertGreaterThanOrEqual(report.ignoredInstalledCount, 3)
        XCTAssertGreaterThanOrEqual(report.unverifiedNameCount, 2)
        XCTAssertEqual(report.candidates.first { $0.url.path.contains("/Caches/") }?.category, .cache)
        XCTAssertEqual(report.candidates.first { $0.url.path.contains("/Caches/") }?.source, .caches)
        XCTAssertEqual(report.candidates.first { $0.url.path.contains("/Containers/") }?.category, .leftover)
        XCTAssertEqual(report.candidates.first { $0.url.path.contains("/Containers/") }?.source, .containers)
    }

    func testFindsSystemComponentsLinkedToMissingAppWithoutMakingThemCleanupCandidates() throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: home) }
        let system = home.appending(path: "SystemLibrary", directoryHint: .isDirectory)
        let helper = system.appending(path: "PrivilegedHelperTools/com.teamviewer.Helper")
        try createFile("SystemLibrary/PrivilegedHelperTools/com.teamviewer.Helper", under: home)
        let daemon = system.appending(path: "LaunchDaemons/com.teamviewer.Helper.plist")
        try writePlist([
            "Label": "com.teamviewer.Helper",
            "AssociatedBundleIdentifiers": ["com.teamviewer.TeamViewer"],
            "Program": helper.path
        ], to: daemon)
        try writePlist([
            "Label": "com.teamviewer.Watcher",
            "AssociatedBundleIdentifiers": ["com.teamviewer.TeamViewer"],
            "Program": system.appending(path: "Application Support/TeamViewer/missing-helper").path
        ], to: system.appending(path: "LaunchDaemons/com.teamviewer.Watcher.plist"))
        let unrelated = system.appending(path: "LaunchDaemons/com.example.standalone.plist")
        try writePlist(["Label": "com.example.standalone"], to: unrelated)
        let plugin = system.appending(path: "Security/SecurityAgentPlugins/TeamViewerAuthPlugin.bundle/Contents/Info.plist")
        try writePlist(["CFBundleIdentifier": "com.teamviewer.AuthorizationPlugin"], to: plugin)
        try createFile("SystemLibrary/Application Support/TeamViewer/settings.db", under: home)
        try createFile("Library/Preferences/com.teamviewer.TeamViewer.plist", under: home)

        let report = CleanupScanner(homeURL: home, systemLibraryURL: system, registeredApp: { _ in false }).scan()
        XCTAssertEqual(Set(report.systemFindings.map(\.name)), [
            "com.teamviewer.Helper.plist", "com.teamviewer.Helper", "com.teamviewer.Watcher.plist",
            "TeamViewerAuthPlugin.bundle",
            "TeamViewer", "com.teamviewer.TeamViewer.plist"
        ])
        XCTAssertTrue(report.systemFindings.first {
            $0.name == "com.teamviewer.Watcher.plist"
        }?.kind.contains("ausente") == true)
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertFalse(report.systemFindings.contains { $0.url == unrelated })

        let installedReport = CleanupScanner(
            homeURL: home, systemLibraryURL: system,
            registeredApp: { $0 == "com.teamviewer.TeamViewer" }
        ).scan()
        XCTAssertEqual(installedReport.systemFindings.map(\.name), ["com.teamviewer.Watcher.plist"])
        XCTAssertNil(installedReport.systemFindings[0].associatedApp,
                     "Com o app instalado, o serviço é mostrado apenas como caminho quebrado")
    }

    func testFlagsMissingUserAgentExecutableButKeepsExistingEmbeddedApp() throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: home) }
        let system = home.appending(path: "SystemLibrary")
        let agentRoot = home.appending(path: "Library/LaunchAgents")
        let missingProgram = home.appending(path: "bin/removed-helper")
        let brokenAgent = agentRoot.appending(path: "com.example.old-service.plist")
        try writePlist([
            "Label": "com.example.old-service", "ProgramArguments": [missingProgram.path]
        ], to: brokenAgent)

        let embeddedApp = home.appending(path: "Library/Application Support/Google/GoogleUpdater.app")
        try writePlist([
            "CFBundleIdentifier": "com.google.GoogleUpdater", "CFBundleName": "GoogleUpdater"
        ], to: embeddedApp.appending(path: "Contents/Info.plist"))
        let updater = embeddedApp.appending(path: "Contents/MacOS/GoogleUpdater")
        try createFile("Library/Application Support/Google/GoogleUpdater.app/Contents/MacOS/GoogleUpdater", under: home)
        try writePlist([
            "Label": "com.google.GoogleUpdater.wake",
            "AssociatedBundleIdentifiers": ["com.google.GoogleUpdater"],
            "Program": updater.path
        ], to: agentRoot.appending(path: "com.google.GoogleUpdater.wake.plist"))

        let scanner = CleanupScanner(homeURL: home, systemLibraryURL: system, registeredApp: { _ in false })
        let report = scanner.scan()
        XCTAssertEqual(report.systemFindings.map(\.name), ["com.example.old-service.plist"])
        XCTAssertNil(report.systemFindings[0].associatedApp)
        XCTAssertTrue(report.systemFindings[0].kind.contains("ausente"))

        try createFile("bin/removed-helper", under: home)
        XCTAssertTrue(scanner.scan().systemFindings.isEmpty)
    }

    private func writePlist(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func createFile(_ relativePath: String, under home: URL) throws {
        let file = home.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: file)
    }
}
