import Darwin
import Foundation

struct DiskNode: Identifiable, Codable, Sendable {
    let url: URL
    let name: String
    let size: Int64
    let fileCount: Int
    let isDirectory: Bool
    let children: [DiskNode]

    var id: URL { url }
}

struct DiskScanReport: Codable, Sendable {
    let rootURL: URL
    let rootName: String
    let scannedBytes: Int64
    let scannedFiles: Int
    let unreadableAreas: Int
    let entries: [DiskNode]
    let volume: DiskVolumeInfo
    let scannedAt: Date
}

struct DiskVolumeInfo: Codable, Sendable {
    let name: String
    let capacity: Int64?
    let available: Int64?
}

struct DiskScanner: Sendable {
    // Arquivos menores continuam contabilizados no tamanho da pasta, mas são
    // agrupados no mapa para manter o cache e a interface leves em discos grandes.
    static let visibleFileThreshold: Int64 = 8 * 1_024 * 1_024

    static func volumeInfo(for url: URL) -> DiskVolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return DiskVolumeInfo(
            name: values?.volumeName ?? "Volume",
            capacity: values?.volumeTotalCapacity.map(Int64.init),
            available: values?.volumeAvailableCapacity.map(Int64.init)
        )
    }

    func scan(
        folder: URL,
        progress: @Sendable (Int) -> Void = { _ in }
    ) -> DiskScanReport {
        let manager = FileManager.default
        let requestedRoot = folder.standardizedFileURL
        let canonicalPath = requestedRoot.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let root = URL(fileURLWithPath: canonicalPath ?? requestedRoot.path, isDirectory: true)
        let volumeKeys: Set<URLResourceKey> = [
            .volumeIdentifierKey
        ]
        let volumeValues = try? root.resourceValues(forKeys: volumeKeys)
        let volumeID = volumeValues?.volumeIdentifier
        let rootNode = MutableDiskNode(url: root, name: root.lastPathComponent, isDirectory: true)
        let traversal = DiskTraversalPolicy(root: root)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .volumeIdentifierKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
        ]
        var unreadableAreas = 0
        var visited = 0

        let enumerator = manager.enumerator(
            at: root,
            // Não antecipa a leitura de metadados de pacotes protegidos.
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                unreadableAreas += 1
                return true
            }
        )

        if enumerator == nil { unreadableAreas += 1 }
        while let url = enumerator?.nextObject() as? URL {
            if Task.isCancelled { break }
            visited += 1
            if visited.isMultiple(of: 5_000) { progress(visited) }

            if traversal.shouldSkipPrivateLibrary(url) {
                enumerator?.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                unreadableAreas += 1
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator?.skipDescendants() }
                continue
            }
            if traversal.shouldSkip(url: url, volumeID: values.volumeIdentifier, rootVolumeID: volumeID) {
                if values.isDirectory == true { enumerator?.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }

            let size = Int64(max(0, values.totalFileAllocatedSize
                                   ?? values.fileAllocatedSize
                                   ?? values.fileSize
                                   ?? 0))
            let relativePath = url.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1)
            let components = relativePath.split(separator: "/")
            guard !components.isEmpty else { continue }
            rootNode.addFile(size: size, components: components)
        }
        progress(visited)
        let volume = Self.volumeInfo(for: root)

        return DiskScanReport(
            rootURL: root,
            rootName: root.path == "/" ? volume.name : root.lastPathComponent,
            scannedBytes: rootNode.size,
            scannedFiles: rootNode.fileCount,
            unreadableAreas: unreadableAreas,
            entries: rootNode.sortedChildren(),
            volume: volume,
            scannedAt: .now
        )
    }
}

private final class MutableDiskNode {
    let url: URL
    let name: String
    var isDirectory: Bool
    var size: Int64 = 0
    var fileCount = 0
    var children: [String: MutableDiskNode] = [:]

    init(url: URL, name: String, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
    }

    func addFile(size fileSize: Int64, components: [Substring]) {
        size += fileSize
        fileCount += 1
        var parent = self
        for (index, part) in components.enumerated() {
            let name = String(part)
            let isLast = index == components.count - 1
            if isLast && fileSize < DiskScanner.visibleFileThreshold { break }
            let child = parent.children[name] ?? MutableDiskNode(
                url: parent.url.appendingPathComponent(name),
                name: name,
                isDirectory: !isLast
            )
            parent.children[name] = child
            child.size += fileSize
            child.fileCount += 1
            parent = child
        }
    }

    func sortedChildren() -> [DiskNode] {
        children.values.map { child in
            DiskNode(
                url: child.url,
                name: child.name,
                size: child.size,
                fileCount: child.fileCount,
                isDirectory: child.isDirectory,
                children: child.sortedChildren()
            )
        }
        .sorted { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
    }
}

private struct DiskTraversalPolicy {
    private static let photoLibraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "aplibrary", "migratedaplibrary"
    ]
    let isStartupRoot: Bool
    let firmlinkPaths: [String]
    let appCachePath: String

    init(root: URL) {
        isStartupRoot = root.path == "/"
        appCachePath = DiskReportCache().fileURL.deletingLastPathComponent().path
        let contents = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)
        firmlinkPaths = contents?.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").first.map(String.init)
        } ?? ["/Applications", "/Library", "/Users", "/private", "/opt"]
    }

    func shouldSkipPrivateLibrary(_ url: URL) -> Bool {
        // A Fototeca tem uma autorização própria no macOS. O mapa de espaço
        // não precisa abrir seu pacote para mostrar a capacidade do volume.
        return Self.photoLibraryExtensions.contains(url.pathExtension.lowercased())
    }

    func shouldSkip(url: URL, volumeID: Any?, rootVolumeID: Any?) -> Bool {
        let path = url.path
        if isStartupRoot {
            if path == appCachePath || path.hasPrefix(appCachePath + "/") { return true }
            let excluded = ["/System/Volumes", "/Volumes", "/dev", "/Network", "/net"]
            if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        }
        guard let rootVolumeID = rootVolumeID as? NSObject,
              let volumeID = volumeID as? NSObject,
              !volumeID.isEqual(rootVolumeID) else { return false }
        return !isStartupRoot || !firmlinkPaths.contains {
            path == $0 || path.hasPrefix($0 + "/")
        }
    }
}
