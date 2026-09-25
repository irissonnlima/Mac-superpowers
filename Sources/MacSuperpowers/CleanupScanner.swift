import AppKit
import Darwin
import Foundation

enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case cache = "Caches"
    case leftover = "Dados de apps"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cache: "externaldrive"
        case .leftover: "square.stack.3d.up"
        }
    }

    var explanation: String {
        switch self {
        case .cache:
            "Pastas temporárias em ~/Library/Caches associadas a apps que não foram encontrados."
        case .leftover:
            "Outras pastas desses apps. Podem conter configurações, sessões e arquivos locais."
        }
    }
}

struct CleanupCandidate: Identifiable, Sendable {
    let url: URL
    let category: CleanupCategory
    let source: ScanSource
    let size: Int64
    let explanation: String

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct SystemFinding: Identifiable, Sendable {
    let url: URL
    let associatedApp: String?
    let kind: String
    let size: Int64

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var appName: String { associatedApp?.split(separator: ".").last.map(String.init) ?? "" }
    var title: String { appName.isEmpty ? name : "\(appName) · \(name)" }
}

struct ScanReport: Sendable {
    let candidates: [CleanupCandidate]
    let systemFindings: [SystemFinding]
    let issues: [String]
    let scannedAt: Date
    let ignoredInstalledCount: Int
    let unverifiedNameCount: Int

    var totalSize: Int64 { candidates.reduce(0) { $0 + $1.size } }
}

struct CleanupScanner: Sendable {
    let homeURL: URL
    let systemLibraryURL: URL
    let registeredApp: @Sendable (String) -> Bool

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemLibraryURL: URL = URL(fileURLWithPath: "/Library", isDirectory: true),
        registeredApp: @escaping @Sendable (String) -> Bool = {
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0).contains {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
    ) {
        self.homeURL = homeURL
        self.systemLibraryURL = systemLibraryURL
        self.registeredApp = registeredApp
    }

    func scan() -> ScanReport {
        let manager = FileManager.default
        let installed = installedApplications(using: manager)
        let library = homeURL.appending(path: "Library", directoryHint: .isDirectory)
        var candidates: [CleanupCandidate] = []
        var issues: [String] = []
        var ignoredInstalledCount = 0
        var unverifiedNameCount = 0

        for source in ScanSource.allCases {
            let root = library.appending(path: source.relativePath, directoryHint: .isDirectory)
            guard manager.fileExists(atPath: root.path) else { continue }
            let children: [URL]
            do {
                children = try manager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                issues.append("Sem acesso a \(root.path): \(error.localizedDescription)")
                continue
            }

            for child in children {
                if Task<Never, Never>.isCancelled { break }
                let identifier: String
                switch assess(child, source: source, installed: installed) {
                case .candidate(let value): identifier = value
                case .installed: ignoredInstalledCount += 1; continue
                case .unverified: unverifiedNameCount += 1; continue
                case .excluded: continue
                }
                let size = byteSize(of: child, using: manager)
                guard size > 0 else { continue }
                candidates.append(CleanupCandidate(
                    url: child,
                    category: source.category,
                    source: source,
                    size: size,
                    explanation: "App \(identifier) não encontrado. Serviços ou extensões ainda podem usar estes dados."
                ))
            }
        }

        candidates.sort { $0.size > $1.size }
        let systemFindings = systemFindings(installed: installed, using: manager, issues: &issues)
        return ScanReport(
            candidates: candidates,
            systemFindings: systemFindings,
            issues: issues,
            scannedAt: .now,
            ignoredInstalledCount: ignoredInstalledCount,
            unverifiedNameCount: unverifiedNameCount
        )
    }

    private func systemFindings(
        installed: InstalledApplications,
        using manager: FileManager,
        issues: inout [String]
    ) -> [SystemFinding] {
        var findings: [URL: SystemFinding] = [:]
        var missingApps: Set<String> = []

        let launchRoots: [(URL, String)] = [
            (systemLibraryURL.appending(path: "LaunchAgents"), "Item de inicialização"),
            (systemLibraryURL.appending(path: "LaunchDaemons"), "Serviço de inicialização"),
            (homeURL.appending(path: "Library/LaunchAgents"), "Item de inicialização do usuário")
        ]
        for (root, kind) in launchRoots {
            guard manager.fileExists(atPath: root.path) else { continue }
            let entries: [URL]
            do {
                entries = try manager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
                )
            } catch {
                issues.append("Sem acesso a \(root.path): \(error.localizedDescription)")
                continue
            }
            for file in entries where file.pathExtension == "plist" {
                guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }

                let programPath = (plist["Program"] as? String)
                    ?? (plist["ProgramArguments"] as? [String])?.first
                let appIDs = (plist["AssociatedBundleIdentifiers"] as? [String])
                    ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
                if let appID = appIDs.first(where: {
                          Self.looksLikeBundleIdentifier($0) &&
                          !installed.hasRelatedApplication($0, registeredApp: registeredApp) &&
                          !programIsAssociatedApp(programPath, identifier: $0)
                }) {
                    missingApps.insert(appID)
                    let serviceKind = programPath.map { $0.hasPrefix("/") && pathIsMissing($0) } == true
                        ? "\(kind) · executável ausente" : kind
                    findings[file] = SystemFinding(
                        url: file, associatedApp: appID, kind: serviceKind,
                        size: byteSize(of: file, using: manager)
                    )
                    if let programPath,
                       let program = referencedComponent(programPath, using: manager) {
                        findings[program] = SystemFinding(
                            url: program, associatedApp: appID,
                            kind: "Componente auxiliar",
                            size: byteSize(of: program, using: manager)
                        )
                    }
                } else if let programPath, programPath.hasPrefix("/"), pathIsMissing(programPath) {
                    findings[file] = SystemFinding(
                        url: file, associatedApp: nil,
                        kind: "Executável ausente · \(kind)",
                        size: byteSize(of: file, using: manager)
                    )
                }
            }
        }

        let plugins = systemLibraryURL.appending(path: "Security/SecurityAgentPlugins", directoryHint: .isDirectory)
        if let entries = try? manager.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            for bundle in entries where bundle.pathExtension == "bundle" {
                guard (try? bundle.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let identifier = Bundle(url: bundle)?.bundleIdentifier,
                      let appID = missingApps.first(where: { relatedVendor(identifier, $0) }) else { continue }
                findings[bundle] = SystemFinding(
                    url: bundle, associatedApp: appID,
                    kind: "Plugin de autenticação",
                    size: byteSize(of: bundle, using: manager)
                )
            }
        }

        for appID in missingApps {
            appendRelatedData(for: appID, to: &findings, using: manager)
        }

        return findings.values.sorted {
            if $0.appName != $1.appName { return $0.appName < $1.appName }
            return $0.url.path < $1.url.path
        }
    }

    private func programIsAssociatedApp(_ path: String?, identifier: String) -> Bool {
        guard let path else { return false }
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if url.pathExtension == "app",
               let bundleID = Bundle(url: url)?.bundleIdentifier,
               bundleID.caseInsensitiveCompare(identifier) == .orderedSame { return true }
            url.deleteLastPathComponent()
        }
        return false
    }

    private func pathIsMissing(_ path: String) -> Bool {
        var metadata = stat()
        return path.withCString { stat($0, &metadata) } != 0 && errno == ENOENT
    }

    private func appendRelatedData(
        for appID: String,
        to findings: inout [URL: SystemFinding],
        using manager: FileManager
    ) {
        let appName = appID.split(separator: ".").last.map(String.init) ?? ""
        guard appName.count >= 5 else { return }
        let userLibrary = homeURL.appending(path: "Library")
        let roots: [(URL, String)] = [
            (systemLibraryURL.appending(path: "Application Support"), "Dados de suporte do sistema"),
            (userLibrary.appending(path: "Application Support"), "Dados de suporte do usuário"),
            (userLibrary.appending(path: "Logs"), "Registros do app")
        ]
        for (root, kind) in roots {
            guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for entry in entries where entry.lastPathComponent.caseInsensitiveCompare(appName) == .orderedSame {
                findings[entry] = SystemFinding(
                    url: entry, associatedApp: appID, kind: kind,
                    size: byteSize(of: entry, using: manager)
                )
            }
        }
        let keyedRoots: [(URL, String)] = [
            (userLibrary.appending(path: "Preferences"), "Preferências do app"),
            (userLibrary.appending(path: "Saved Application State"), "Estado salvo do app")
        ]
        for (root, kind) in keyedRoots {
            guard let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for entry in entries where entry.lastPathComponent.lowercased().hasPrefix(appID.lowercased() + ".") {
                findings[entry] = SystemFinding(
                    url: entry, associatedApp: appID, kind: kind,
                    size: byteSize(of: entry, using: manager)
                )
            }
        }
    }

    private func referencedComponent(_ path: String, using manager: FileManager) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let root = systemLibraryURL.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"),
              manager.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return nil
        }
        return url
    }

    private func relatedVendor(_ identifier: String, _ appID: String) -> Bool {
        let vendor = appID.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
        return identifier.lowercased().hasPrefix(vendor + ".")
    }

    private func assess(
        _ url: URL,
        source: ScanSource,
        installed: InstalledApplications
    ) -> CandidateAssessment {
        let name = url.lastPathComponent
        let lowercasedName = name.lowercased()
        guard !name.hasPrefix("."),
              !Self.protectedPrefixes.contains(where: lowercasedName.hasPrefix),
              !lowercasedName.hasSuffix(".cli") else { return .excluded }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return .excluded
        }
        guard let identifier = source.bundleIdentifier(from: name),
              Self.looksLikeBundleIdentifier(identifier) else { return .unverified }
        guard !installed.hasRelatedApplication(identifier, registeredApp: registeredApp) else {
            return .installed
        }
        return .candidate(identifier)
    }

    static func looksLikeBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return parts.count >= 3 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    private static let protectedPrefixes = [
        "com.apple.", "group.", "systemgroup.", "org.cups.",
        "org.sparkle-project.", "org.swift."
    ]

    private func installedApplications(using manager: FileManager) -> InstalledApplications {
        var identifiers: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            if let identifier = app.bundleIdentifier {
                identifiers.insert(identifier.lowercased())
            }
        }
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            homeURL.appending(path: "Applications", directoryHint: .isDirectory)
        ]
        for root in roots {
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                if let identifier = Bundle(url: url)?.bundleIdentifier {
                    identifiers.insert(identifier.lowercased())
                }
                enumerator.skipDescendants()
            }
        }
        return InstalledApplications(identifiers: identifiers)
    }

    private func byteSize(of url: URL, using manager: FileManager) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return 0 }
        if values.isDirectory != true {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]))?.totalFileAllocatedSize
                ?? (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var size: Int64 = 0
        for case let file as URL in enumerator {
            if Task<Never, Never>.isCancelled { break }
            guard let fileValues = try? file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey
            ]), fileValues.isRegularFile == true, fileValues.isSymbolicLink != true else { continue }
            size += Int64(fileValues.totalFileAllocatedSize ?? fileValues.fileSize ?? 0)
        }
        return size
    }
}

private enum CandidateAssessment {
    case candidate(String)
    case installed
    case unverified
    case excluded
}

private struct InstalledApplications {
    let identifiers: Set<String>

    func hasRelatedApplication(
        _ value: String,
        registeredApp: (String) -> Bool
    ) -> Bool {
        let candidate = value.lowercased()
        if identifiers.contains(where: { installed in
            candidate == installed || candidate.hasPrefix(installed + ".") ||
                installed.hasPrefix(candidate + ".")
        }) { return true }

        // A folder can be shared by products from the same developer.
        let vendor = candidate.split(separator: ".").prefix(2).joined(separator: ".")
        if identifiers.contains(where: { $0.hasPrefix(vendor + ".") }) { return true }

        var components = value.split(separator: ".").map(String.init)
        while components.count >= 3 {
            if registeredApp(components.joined(separator: ".")) { return true }
            components.removeLast()
        }
        return false
    }
}

enum ScanSource: CaseIterable, Sendable {
    case caches, applicationSupport, containers, httpStorages, webKit

    var relativePath: String {
        switch self {
        case .caches: "Caches"
        case .applicationSupport: "Application Support"
        case .containers: "Containers"
        case .httpStorages: "HTTPStorages"
        case .webKit: "WebKit"
        }
    }

    var category: CleanupCategory {
        switch self {
        case .caches: .cache
        default: .leftover
        }
    }

    var displayName: String {
        switch self {
        case .caches: "Cache temporário"
        case .applicationSupport: "Dados de suporte"
        case .containers: "Contêiner do app"
        case .httpStorages: "Armazenamento de rede"
        case .webKit: "Dados da web"
        }
    }

    var detail: String {
        switch self {
        case .caches: "arquivos que o app pode recriar"
        case .applicationSupport: "pode incluir configurações e arquivos"
        case .containers: "pode incluir documentos e preferências"
        case .httpStorages: "pode incluir dados de navegação"
        case .webKit: "pode incluir conteúdo e dados de sites"
        }
    }

    func bundleIdentifier(from name: String) -> String? {
        name
    }
}
