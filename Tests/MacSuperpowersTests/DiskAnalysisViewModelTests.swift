import Foundation
import XCTest
@testable import MacSuperpowers

@MainActor
final class DiskAnalysisViewModelTests: XCTestCase {
    func testOpensCachedMapWithoutStartingAnotherRootScan() async throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: folder) }
        let cache = DiskReportCache(fileURL: folder.appendingPathComponent("report.json.lzfse"))
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let report = DiskScanReport(
            rootURL: root, rootName: "Macintosh HD", scannedBytes: 42,
            scannedFiles: 1, unreadableAreas: 0, entries: [],
            volume: DiskVolumeInfo(name: "Macintosh HD", capacity: 100, available: 58),
            scannedAt: .now
        )
        XCTAssertTrue(cache.save(report))

        let model = DiskAnalysisViewModel(cache: cache)
        model.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isLoadingCache && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.isLoadingCache)
        XCTAssertFalse(model.isScanning)
        XCTAssertTrue(model.showingCachedReport)
        XCTAssertEqual(model.report?.scannedBytes, 42)
    }
}
