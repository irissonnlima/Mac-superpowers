import AppKit
import Combine
import Foundation

struct CleanupSelectionItem: Identifiable {
    let url: URL
    let name: String
    let size: Int64
    let isSystemComponent: Bool

    var id: URL { url }
}

@MainActor
final class CleanupViewModel: ObservableObject {
    @Published private(set) var report: ScanReport?
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress = 0.0
    @Published private(set) var isTrashing = false
    @Published var selectedURLs: Set<URL> = []
    @Published var notice: String?

    private let scanOperation: @Sendable () -> ScanReport
    private let minimumScanDuration: Duration
    private let trashOperation: @MainActor @Sendable ([CleanupCandidate], [SystemFinding]) async -> TrashResult

    init(
        scanOperation: @escaping @Sendable () -> ScanReport = { CleanupScanner().scan() },
        minimumScanDuration: Duration = .seconds(2),
        trashOperation: @escaping @MainActor @Sendable ([CleanupCandidate], [SystemFinding]) async -> TrashResult = {
            await CleanupTrash.recycle(candidates: $0, systemFindings: $1)
        }
    ) {
        self.scanOperation = scanOperation
        self.minimumScanDuration = minimumScanDuration
        self.trashOperation = trashOperation
    }

    var selectedCandidates: [CleanupCandidate] {
        report?.candidates.filter { selectedURLs.contains($0.url) } ?? []
    }

    var selectedSystemFindings: [SystemFinding] {
        report?.systemFindings.filter { selectedURLs.contains($0.url) } ?? []
    }

    var selectedItems: [CleanupSelectionItem] {
        selectedCandidates.map {
            CleanupSelectionItem(url: $0.url, name: $0.name, size: $0.size, isSystemComponent: false)
        } + selectedSystemFindings.map {
            CleanupSelectionItem(url: $0.url, name: $0.name, size: $0.size, isSystemComponent: true)
        }
    }

    var selectedCount: Int { selectedItems.count }
    var availableCount: Int { (report?.candidates.count ?? 0) + (report?.systemFindings.count ?? 0) }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    func scan() {
        guard !isScanning && !isTrashing else { return }
        isScanning = true
        scanProgress = 0
        report = nil
        selectedURLs = []
        notice = nil
        let operation = scanOperation
        let duration = minimumScanDuration
        Task {
            let clock = ContinuousClock()
            let startedAt = clock.now
            let durationParts = duration.components
            let durationSeconds = max(
                Double(durationParts.seconds) + Double(durationParts.attoseconds) / 1e18,
                0.01
            )
            let progressTask = Task {
                while !Task.isCancelled {
                    let elapsed = startedAt.duration(to: clock.now).components
                    let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                    scanProgress = min(0.92, 0.92 * elapsedSeconds / durationSeconds)
                    if scanProgress >= 0.92 { break }
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            let minimumTime = Task { try? await Task.sleep(for: duration) }
            let result = await Task.detached(priority: .userInitiated) { operation() }.value
            _ = await minimumTime.value
            progressTask.cancel()
            _ = await progressTask.value
            for step in 1...14 {
                scanProgress = 0.92 + 0.08 * Double(step) / 14
                try? await Task.sleep(for: .milliseconds(25))
            }
            try? await Task.sleep(for: .milliseconds(180))
            report = result
            isScanning = false
        }
    }

    func toggle(_ url: URL) {
        guard !isTrashing,
              report?.candidates.contains(where: { $0.url == url }) == true ||
              report?.systemFindings.contains(where: { $0.url == url }) == true else { return }
        if selectedURLs.contains(url) { selectedURLs.remove(url) }
        else { selectedURLs.insert(url) }
    }

    func selectAll(_ urls: [URL]) {
        selectedURLs.formUnion(urls)
    }

    func deselectAll(_ urls: [URL]) {
        selectedURLs.subtract(urls)
    }

    func trashSelected() {
        guard let report, selectedCount > 0, !isTrashing else { return }
        let candidates = selectedCandidates
        let systemFindings = selectedSystemFindings
        let operation = trashOperation
        isTrashing = true
        Task {
            let result = await operation(candidates, systemFindings)
            let removed = Set(result.succeeded)
            self.report = ScanReport(
                candidates: report.candidates.filter { !removed.contains($0.url) },
                systemFindings: report.systemFindings.filter { !removed.contains($0.url) },
                issues: report.issues,
                scannedAt: report.scannedAt,
                ignoredInstalledCount: report.ignoredInstalledCount,
                unverifiedNameCount: report.unverifiedNameCount
            )
            selectedURLs.subtract(removed)
            isTrashing = false
            let movedLabel = removed.count == 1 ? "1 item movido" : "\(removed.count) itens movidos"
            if result.failed.isEmpty {
                notice = "\(movedLabel) para o Lixo. Você pode recuperar pelo Finder. Serviços de inicialização podem exigir reinício para deixar de aparecer no macOS."
            } else {
                notice = "\(movedLabel). \(result.failed.count) falharam: \(result.failed.prefix(2).joined(separator: " • "))"
            }
        }
    }
}
