import Combine
import Foundation

private let startupDiskRoot = URL(fileURLWithPath: "/", isDirectory: true)

@MainActor
final class DiskAnalysisViewModel: ObservableObject {
    @Published private(set) var report: DiskScanReport?
    @Published private(set) var volumeInfo = DiskScanner.volumeInfo(for: startupDiskRoot)
    @Published private(set) var isScanning = false
    @Published private(set) var isLoadingCache = false
    @Published private(set) var scannedItems = 0
    @Published private(set) var showingCachedReport = false
    @Published private(set) var cacheUnavailable = false

    private let cache: DiskReportCache
    private var hasStarted = false
    private var scanTask: Task<DiskScanReport, Never>?
    private var scanID = UUID()

    init(cache: DiskReportCache = DiskReportCache()) {
        self.cache = cache
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isLoadingCache = true

        let cache = self.cache
        Task { [weak self] in
            let cached = await Task.detached(priority: .utility) { cache.load() }.value
            guard let self else { return }
            self.isLoadingCache = false
            guard self.report == nil, !self.isScanning else { return }
            if let cached {
                self.report = cached
                self.showingCachedReport = true
            } else {
                self.scanRoot()
            }
        }
    }

    func scanRoot() {
        scanTask?.cancel()
        scanID = UUID()
        let activeID = scanID
        volumeInfo = DiskScanner.volumeInfo(for: startupDiskRoot)
        scannedItems = 0
        isScanning = true
        isLoadingCache = false
        cacheUnavailable = false

        let updateProgress: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor in
                guard let self, self.scanID == activeID else { return }
                self.scannedItems = count
            }
        }
        let root = startupDiskRoot
        let task = Task.detached(priority: .userInitiated) {
            DiskScanner().scan(folder: root, progress: updateProgress)
        }
        scanTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self, self.scanID == activeID else { return }
            self.report = result
            self.volumeInfo = result.volume
            self.scannedItems = result.scannedFiles
            self.showingCachedReport = false
            self.isScanning = false
            self.scanTask = nil

            let cache = self.cache
            let saved = await Task.detached(priority: .utility) { cache.save(result) }.value
            guard self.scanID == activeID else { return }
            self.cacheUnavailable = !saved
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        scannedItems = 0
        isScanning = false
    }
}
