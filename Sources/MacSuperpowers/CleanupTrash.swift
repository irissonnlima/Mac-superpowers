import AppKit
import Foundation

struct TrashResult: Sendable {
    let succeeded: [URL]
    let failed: [String]
}

struct SystemTrashPolicy: Sendable {
    let homeURL: URL
    let systemLibraryURL: URL

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemLibraryURL: URL = URL(fileURLWithPath: "/Library", isDirectory: true)
    ) {
        self.homeURL = homeURL
        self.systemLibraryURL = systemLibraryURL
    }

    func allows(_ url: URL) -> Bool {
        guard url.isFileURL,
              url.path.rangeOfCharacter(from: .controlCharacters) == nil,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return false
        }
        let normalized = url.standardizedFileURL
        let resolved = normalized.resolvingSymlinksInPath()
        return allowedRoots.contains { root in
            let rootPath = root.standardizedFileURL.path + "/"
            let resolvedRootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            return normalized.path.hasPrefix(rootPath) && resolved.path.hasPrefix(resolvedRootPath)
        }
    }

    private var allowedRoots: [URL] {
        let userLibrary = homeURL.appending(path: "Library")
        return [
            systemLibraryURL.appending(path: "LaunchAgents"),
            systemLibraryURL.appending(path: "LaunchDaemons"),
            systemLibraryURL.appending(path: "PrivilegedHelperTools"),
            systemLibraryURL.appending(path: "Security/SecurityAgentPlugins"),
            systemLibraryURL.appending(path: "Application Support"),
            userLibrary.appending(path: "LaunchAgents"),
            userLibrary.appending(path: "Application Support"),
            userLibrary.appending(path: "Logs"),
            userLibrary.appending(path: "Preferences"),
            userLibrary.appending(path: "Saved Application State")
        ]
    }
}

@MainActor
enum CleanupTrash {
    static func recycle(candidates: [CleanupCandidate], systemFindings: [SystemFinding]) async -> TrashResult {
        let policy = SystemTrashPolicy()
        let manager = FileManager.default
        let userLibrary = manager.homeDirectoryForCurrentUser.appending(path: "Library")
        let currentReport = await Task.detached(priority: .userInitiated) { CleanupScanner().scan() }.value
        let currentCandidates = Set(currentReport.candidates.map(\.url))
        let currentSystemFindings = Set(currentReport.systemFindings.map(\.url))
        var valid: [URL] = []
        var failed: [String] = []
        for candidate in candidates {
            let expectedParent = userLibrary.appending(path: candidate.source.relativePath).standardizedFileURL
            guard currentCandidates.contains(candidate.url),
                  candidate.url.deletingLastPathComponent().standardizedFileURL == expectedParent,
                  (try? candidate.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  manager.fileExists(atPath: candidate.url.path) else {
                failed.append("\(candidate.name): não aparece mais na análise ou o caminho mudou")
                continue
            }
            valid.append(candidate.url.standardizedFileURL)
        }
        for finding in systemFindings {
            guard currentSystemFindings.contains(finding.url),
                  policy.allows(finding.url), manager.fileExists(atPath: finding.url.path) else {
                failed.append("\(finding.name): não aparece mais na análise ou o caminho mudou")
                continue
            }
            valid.append(finding.url.standardizedFileURL)
        }
        guard !valid.isEmpty else { return TrashResult(succeeded: [], failed: failed) }

        // If a parent folder is selected, the Finder moves its children with it.
        let ordered = valid.sorted { $0.pathComponents.count < $1.pathComponents.count }
        var roots: [URL] = []
        for url in ordered where !roots.contains(where: { url.path.hasPrefix($0.path + "/") }) {
            roots.append(url)
        }

        let protectedRoots = roots.filter { $0.path.hasPrefix("/Library/") }
        let ordinaryRoots = roots.filter { !$0.path.hasPrefix("/Library/") }
        var movedRoots: Set<URL> = []
        var failureReasons: [URL: String] = [:]

        if !ordinaryRoots.isEmpty {
            let moved = await withCheckedContinuation {
                (continuation: CheckedContinuation<([URL], String?), Never>) in
                NSWorkspace.shared.recycle(ordinaryRoots) { destinations, error in
                    continuation.resume(returning: (Array(destinations.keys), error?.localizedDescription))
                }
            }
            movedRoots.formUnion(moved.0.map(\.standardizedFileURL))
            for url in ordinaryRoots where !movedRoots.contains(url) {
                failureReasons[url] = moved.1 ?? "não foi possível mover para o Lixo"
            }
        }

        if !protectedRoots.isEmpty {
            let protectedResult = await Task.detached(priority: .userInitiated) {
                PrivilegedTrash.moveToUserTrash(protectedRoots)
            }.value
            movedRoots.formUnion(protectedResult.succeeded)
            failureReasons.merge(protectedResult.failed) { _, new in new }
        }

        let succeeded = valid.filter { url in
            roots.contains { root in
                movedRoots.contains(root) && (url == root || url.path.hasPrefix(root.path + "/"))
            }
        }
        let succeededSet = Set(succeeded)
        failed += valid.filter { !succeededSet.contains($0) }.map { url in
            let root = roots.first { url == $0 || url.path.hasPrefix($0.path + "/") }
            return "\(url.lastPathComponent): \(root.flatMap { failureReasons[$0] } ?? "não foi possível mover para o Lixo")"
        }
        return TrashResult(succeeded: succeeded, failed: failed)
    }
}
