import AppKit
import Foundation

struct PrivilegedTrashResult: Sendable {
    let succeeded: Set<URL>
    let failed: [URL: String]
}

/// Moves reviewed /Library findings into this user's Trash after macOS asks for an administrator.
/// The elevated command invokes only the system `mv` binary with individually quoted paths.
enum PrivilegedTrash {
    static func moveToUserTrash(_ roots: [URL]) -> PrivilegedTrashResult {
        guard !roots.isEmpty else { return PrivilegedTrashResult(succeeded: [], failed: [:]) }

        let policy = SystemTrashPolicy()
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let trash = home.appending(path: ".Trash", directoryHint: .isDirectory)
        let stage = trash.appending(path: "Mac Superpowers - \(UUID().uuidString)", directoryHint: .isDirectory)
        var failed: [URL: String] = [:]
        var destinations: [URL: URL] = [:]

        do {
            // Never let an elevated command follow a replacement Trash symlink.
            if manager.fileExists(atPath: trash.path) {
                let values = try trash.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw TrashSetupError.invalidTrashDirectory
                }
            } else {
                try manager.createDirectory(
                    at: trash, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try manager.createDirectory(at: stage, withIntermediateDirectories: false)
            for root in roots {
                guard root.path.hasPrefix("/Library/"), policy.allows(root),
                      manager.fileExists(atPath: root.path) else {
                    failed[root] = "o caminho protegido mudou; analise novamente"
                    continue
                }
                let relative = String(root.path.dropFirst("/Library/".count))
                let destination = stage.appending(path: relative)
                try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                destinations[root] = destination
            }
        } catch {
            return PrivilegedTrashResult(
                succeeded: [],
                failed: Dictionary(uniqueKeysWithValues: roots.map {
                    ($0, "não foi possível preparar o Lixo: \(error.localizedDescription)")
                })
            )
        }

        guard !destinations.isEmpty else {
            try? manager.removeItem(at: stage)
            return PrivilegedTrashResult(succeeded: [], failed: failed)
        }

        let ordered = roots.filter { destinations[$0] != nil }
        let commands = ordered.compactMap { source -> String? in
            guard let destination = destinations[source] else { return nil }
            return "/bin/mv -n \(shellQuote(source.path)) \(shellQuote(destination.path))"
        }
        let shellScript = "umask 077; " + commands.joined(separator: "; ")
        let appleScript = "do shell script \(appleScriptQuote(shellScript)) with administrator privileges"
        var scriptError: NSDictionary?
        let descriptor = NSAppleScript(source: appleScript)?.executeAndReturnError(&scriptError)
        let authorizationError: String? = {
            guard descriptor == nil else { return nil }
            let code = scriptError?["NSAppleScriptErrorNumber"] as? Int
            if code == -128 { return "autorização administrativa cancelada" }
            return (scriptError?["NSAppleScriptErrorMessage"] as? String)
                ?? "não foi possível obter autorização administrativa"
        }()

        var succeeded: Set<URL> = []
        for (source, destination) in destinations {
            if !manager.fileExists(atPath: source.path), manager.fileExists(atPath: destination.path) {
                succeeded.insert(source)
            } else {
                failed[source] = authorizationError ?? "o macOS não conseguiu mover este item"
            }
        }
        if succeeded.isEmpty { try? manager.removeItem(at: stage) }
        return PrivilegedTrashResult(succeeded: succeeded, failed: failed)
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private enum TrashSetupError: LocalizedError {
    case invalidTrashDirectory

    var errorDescription: String? {
        "a pasta Lixo não é um diretório seguro"
    }
}
