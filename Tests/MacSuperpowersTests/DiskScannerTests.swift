import Foundation
import XCTest
@testable import MacSuperpowers

final class DiskScannerTests: XCTestCase {
    func testBuildsFolderHierarchyAndSkipsSymbolicLinks() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let projects = documents.appendingPathComponent("Projects", isDirectory: true)
        let deepFolder = projects.appendingPathComponent("One/Two/Three/Four", isDirectory: true)
        try manager.createDirectory(at: deepFolder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        try Data(repeating: 1, count: 4_096).write(to: documents.appendingPathComponent("notes.txt"))
        try Data(repeating: 2, count: 8_192).write(to: projects.appendingPathComponent("work.dat"))
        try Data(repeating: 3, count: 2_048).write(to: root.appendingPathComponent(".hidden"))
        try Data(repeating: 4, count: 1_024).write(to: deepFolder.appendingPathComponent("deep.txt"))
        try manager.createSymbolicLink(
            at: root.appendingPathComponent("loop"),
            withDestinationURL: root
        )

        let report = DiskScanner().scan(folder: root)

        XCTAssertEqual(report.scannedFiles, 4)
        XCTAssertEqual(report.entries.count, 1, "Arquivos pequenos devem ser agrupados no mapa")
        XCTAssertGreaterThan(report.scannedBytes, 0)
        let documentsNode = try XCTUnwrap(report.entries.first { $0.name == "Documents" })
        XCTAssertEqual(documentsNode.fileCount, 3)
        XCTAssertTrue(documentsNode.isDirectory)
        let deepest = ["Projects", "One", "Two", "Three", "Four"].reduce(documentsNode as DiskNode?) {
            current, name in current?.children.first { $0.name == name }
        }
        XCTAssertNotNil(deepest, "A hierarquia precisa continuar além de três níveis")
        XCTAssertNil(report.entries.first { $0.name == "loop" })
    }

    func testPersistsAndLoadsRootReportFromCache() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: folder) }
        let cache = DiskReportCache(fileURL: folder.appendingPathComponent("report.json.lzfse"))
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let report = DiskScanReport(
            rootURL: root, rootName: "Macintosh HD", scannedBytes: 42,
            scannedFiles: 1, unreadableAreas: 0,
            entries: [DiskNode(url: root.appendingPathComponent("Users"), name: "Users",
                               size: 42, fileCount: 1, isDirectory: true, children: [])],
            volume: DiskVolumeInfo(name: "Macintosh HD", capacity: 100, available: 58),
            scannedAt: .now
        )

        XCTAssertTrue(cache.save(report))
        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.rootURL.path, "/")
        XCTAssertEqual(loaded.scannedBytes, 42)
        XCTAssertEqual(loaded.entries.first?.name, "Users")
        let permissions = try manager.attributesOfItem(atPath: cache.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testSkipsPhotoLibrariesWithoutReadingTheirContents() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Pictures/Photos Library.photoslibrary", isDirectory: true)
        try manager.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try Data(repeating: 1, count: 4_096).write(to: library.appendingPathComponent("private-photo.jpg"))
        try Data(repeating: 2, count: 8_192).write(to: root.appendingPathComponent("visible.dat"))

        let report = DiskScanner().scan(folder: root)

        XCTAssertEqual(report.scannedFiles, 1)
        XCTAssertFalse(report.entries.contains { $0.name == "Pictures" })
    }

    func testRootFoldersKeepDistinctColorsThroughDescendants() {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let child = DiskNode(url: root.appendingPathComponent("Users/alice"), name: "alice",
                             size: 60, fileCount: 1, isDirectory: true, children: [])
        let users = DiskNode(url: root.appendingPathComponent("Users"), name: "Users",
                             size: 60, fileCount: 1, isDirectory: true, children: [child])
        let system = DiskNode(url: root.appendingPathComponent("System"), name: "System",
                              size: 40, fileCount: 1, isDirectory: true, children: [])

        let sectors = DiskSector.build(from: [users, system], total: 100, rootGroup: nil)
        XCTAssertEqual(sectors.first { $0.node?.name == "Users" }?.groupIndex, 0)
        XCTAssertEqual(sectors.first { $0.node?.name == "alice" }?.groupIndex, 0)
        XCTAssertEqual(sectors.first { $0.node?.name == "System" }?.groupIndex, 1)
    }

    func testFocusedFolderRedistributesColorsAndChartHitOpensItsSector() throws {
        let root = URL(fileURLWithPath: "/Users", isDirectory: true)
        let documents = DiskNode(url: root.appendingPathComponent("Documents"), name: "Documents",
                                 size: 60, fileCount: 1, isDirectory: true, children: [])
        let library = DiskNode(url: root.appendingPathComponent("Library"), name: "Library",
                               size: 40, fileCount: 1, isDirectory: true, children: [])
        let sectors = DiskSector.build(from: [documents, library], total: 100, rootGroup: nil)

        XCTAssertEqual(sectors.first { $0.node?.name == "Documents" }?.groupIndex, 0)
        XCTAssertEqual(sectors.first { $0.node?.name == "Library" }?.groupIndex, 1)

        let point = CGPoint(x: 125, y: 75)
        let hit = try XCTUnwrap(DiskSector.hitTest(sectors, at: point, diameter: 200))
        XCTAssertEqual(hit.node?.url, documents.url)
    }

    func testSingleDominantChildRecolorsItsSubfoldersWhenFocused() {
        let root = URL(fileURLWithPath: "/Users", isDirectory: true)
        let library = DiskNode(url: root.appendingPathComponent("alice/Library"), name: "Library",
                               size: 60, fileCount: 1, isDirectory: true, children: [])
        let documents = DiskNode(url: root.appendingPathComponent("alice/Documents"), name: "Documents",
                                 size: 40, fileCount: 1, isDirectory: true, children: [])
        let home = DiskNode(url: root.appendingPathComponent("alice"), name: "alice",
                            size: 100, fileCount: 2, isDirectory: true,
                            children: [library, documents])

        let focused = DiskSector.build(from: [home], total: 100, rootGroup: nil)
        XCTAssertEqual(focused.first { $0.node?.name == "alice" }?.groupIndex, 0)
        XCTAssertEqual(focused.first { $0.node?.name == "Library" }?.groupIndex, 0)
        XCTAssertEqual(focused.first { $0.node?.name == "Documents" }?.groupIndex, 1)

        let parentMap = DiskSector.build(from: [home], total: 100, rootGroup: 3)
        XCTAssertEqual(parentMap.first { $0.node?.name == "Library" }?.groupIndex, 3)
        XCTAssertEqual(parentMap.first { $0.node?.name == "Documents" }?.groupIndex, 3)
    }
}
