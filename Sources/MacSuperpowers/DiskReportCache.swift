import Foundation

struct DiskReportCache: Sendable {
    private static let currentVersion = 2
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appending(path: "MacSuperpowers/DiskReport.json.lzfse")
        }
    }

    func load() -> DiskScanReport? {
        let data: Data?
        if let compressed = try? Data(contentsOf: fileURL) {
            data = try? (compressed as NSData).decompressed(using: .lzfse) as Data
        } else if fileURL.pathExtension == "lzfse" {
            // Aceita o cache da versão anterior até a próxima varredura terminar.
            data = try? Data(contentsOf: fileURL.deletingPathExtension())
        } else {
            data = nil
        }
        guard let data,
              let cached = try? JSONDecoder().decode(CachedReport.self, from: data),
              cached.version == Self.currentVersion,
              cached.report.rootURL.path == "/" else { return nil }
        return cached.report
    }

    @discardableResult
    func save(_ report: DiskScanReport) -> Bool {
        guard report.rootURL.path == "/" else { return false }
        do {
            let manager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(CachedReport(version: Self.currentVersion, report: report))
            let compressed = try (data as NSData).compressed(using: .lzfse) as Data
            try compressed.write(to: fileURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            if fileURL.pathExtension == "lzfse" {
                try? manager.removeItem(at: fileURL.deletingPathExtension())
            }
            return true
        } catch {
            return false
        }
    }
}

private struct CachedReport: Codable {
    let version: Int
    let report: DiskScanReport
}
