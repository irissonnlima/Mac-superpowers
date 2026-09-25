import Foundation
import XCTest
@testable import MacSuperpowers

@MainActor
final class CleanupViewModelTests: XCTestCase {
    func testScanClearsPreviousReportAndLastsAtLeastTwoSeconds() async throws {
        let report = ScanReport(
            candidates: [], systemFindings: [], issues: [], scannedAt: .now,
            ignoredInstalledCount: 0, unverifiedNameCount: 0
        )
        let model = CleanupViewModel(scanOperation: { report })
        let clock = ContinuousClock()

        let firstStart = clock.now
        model.scan()
        XCTAssertTrue(model.isScanning)
        XCTAssertEqual(model.scanProgress, 0)
        XCTAssertNil(model.report)
        try await waitForScan(model, clock: clock)
        XCTAssertGreaterThanOrEqual(firstStart.duration(to: clock.now), .seconds(2))
        XCTAssertNotNil(model.report)
        XCTAssertEqual(model.scanProgress, 1)

        model.scan()
        XCTAssertTrue(model.isScanning)
        XCTAssertEqual(model.scanProgress, 0)
        XCTAssertNil(model.report, "A análise anterior deve desaparecer ao reanalisar")
        try await waitForScan(model, clock: clock)
    }

    func testSelectedSystemFindingCanBeMovedAndLeavesTheReport() async throws {
        let url = URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.old.plist")
        let finding = SystemFinding(
            url: url, associatedApp: "com.example.Old", kind: "Serviço de inicialização", size: 4096
        )
        let report = ScanReport(
            candidates: [], systemFindings: [finding], issues: [], scannedAt: .now,
            ignoredInstalledCount: 0, unverifiedNameCount: 0
        )
        let model = CleanupViewModel(
            scanOperation: { report }, minimumScanDuration: .milliseconds(1),
            trashOperation: { _, findings in
                TrashResult(succeeded: findings.map(\.url), failed: [])
            }
        )
        let clock = ContinuousClock()
        model.scan()
        try await waitForScan(model, clock: clock)

        model.toggle(url)
        XCTAssertEqual(model.selectedCount, 1)
        XCTAssertEqual(model.selectedSize, 4096)
        model.trashSelected()
        while model.isTrashing { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertTrue(model.report?.systemFindings.isEmpty == true)
        XCTAssertTrue(model.selectedURLs.isEmpty)
        XCTAssertTrue(model.notice?.contains("1 item") == true)
    }

    func testFailedSystemMoveKeepsFindingSelectedForReview() async throws {
        let url = URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.old.plist")
        let finding = SystemFinding(
            url: url, associatedApp: "com.example.Old", kind: "Serviço de inicialização", size: 4096
        )
        let report = ScanReport(
            candidates: [], systemFindings: [finding], issues: [], scannedAt: .now,
            ignoredInstalledCount: 0, unverifiedNameCount: 0
        )
        let model = CleanupViewModel(
            scanOperation: { report }, minimumScanDuration: .milliseconds(1),
            trashOperation: { _, _ in TrashResult(succeeded: [], failed: ["Permissão negada"]) }
        )
        model.scan()
        try await waitForScan(model, clock: ContinuousClock())
        model.toggle(url)
        model.trashSelected()
        while model.isTrashing { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(model.report?.systemFindings.count, 1)
        XCTAssertTrue(model.selectedURLs.contains(url))
        XCTAssertTrue(model.notice?.contains("Permissão negada") == true)
    }

    private func waitForScan(_ model: CleanupViewModel, clock: ContinuousClock) async throws {
        let deadline = clock.now.advanced(by: .seconds(5))
        while model.isScanning && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.isScanning, "A análise deve terminar dentro do limite de teste")
    }
}
