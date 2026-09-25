import AppKit
import SwiftUI

private enum Destination: String, Hashable, CaseIterable {
    case overview = "Visão geral"
    case caches = "Caches"
    case leftovers = "Dados de apps"
    case system = "Serviços e componentes"
    case disk = "Disco"
    case monitor = "Monitor"

    var symbol: String {
        switch self {
        case .overview: "sparkle.magnifyingglass"
        case .caches: "externaldrive"
        case .leftovers: "square.stack.3d.up"
        case .system: "gearshape.2"
        case .disk: "internaldrive"
        case .monitor: "waveform.path.ecg"
        }
    }

    var category: CleanupCategory? {
        switch self {
        case .overview: nil
        case .caches: .cache
        case .leftovers: .leftover
        case .system: nil
        case .disk: nil
        case .monitor: nil
        }
    }

    var explanation: String {
        switch self {
        case .overview:
            "Reúne caches, dados e componentes do sistema ligados a apps não encontrados."
        case .caches:
            "Arquivos temporários em ~/Library/Caches de apps que não foram encontrados."
        case .leftovers:
            "Outros dados de apps não encontrados. Podem guardar configurações, sessões e arquivos locais."
        case .system:
            "Itens de inicialização e dados relacionados em /Library e na sua Biblioteca."
        case .disk:
            ""
        case .monitor:
            ""
        }
    }
}

struct ContentView: View {
    @StateObject private var model = CleanupViewModel()
    @StateObject private var diskModel = DiskAnalysisViewModel()
    @StateObject private var monitorModel = MonitorViewModel()
    @State private var destination: Destination = .overview
    @State private var showingTrashConfirmation = false
    @State private var showingSelectionDetails = false

    private var visibleCandidates: [CleanupCandidate] {
        guard destination != .system, destination != .disk, destination != .monitor else { return [] }
        return model.report?.candidates.filter { destination.category == nil || $0.category == destination.category } ?? []
    }

    private var visibleSystemFindings: [SystemFinding] {
        guard destination == .overview || destination == .system else { return [] }
        return model.report?.systemFindings ?? []
    }

    private var allVisibleSelected: Bool {
        !visibleSelectionURLs.isEmpty && visibleSelectionURLs.allSatisfy { model.selectedURLs.contains($0) }
    }

    private var visibleSelectionURLs: [URL] {
        visibleCandidates.map(\.url) + visibleSystemFindings.map(\.url)
    }

    private var allSystemSelected: Bool {
        !visibleSystemFindings.isEmpty && visibleSystemFindings.allSatisfy { model.selectedURLs.contains($0.url) }
    }

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(248, max(226, geometry.size.width * 0.24))
            let contentWidth = max(0, geometry.size.width - sidebarWidth)

            ZStack {
                BlurBackground()
                    .ignoresSafeArea()
                if model.isScanning {
                    ScanSplashView(progress: model.scanProgress)
                        .transition(.opacity)
                } else {
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: sidebarWidth)
                        if destination == .disk {
                            DiskAnalysisView(model: diskModel, width: contentWidth)
                                .frame(width: contentWidth)
                        } else if destination == .monitor {
                            MonitorView(model: monitorModel, width: contentWidth)
                                .frame(width: contentWidth)
                        } else {
                            mainContent(width: contentWidth)
                                .frame(width: contentWidth)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                    .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.easeInOut(duration: 0.25), value: model.isScanning)
        .frame(minWidth: 900, minHeight: 620)
        .confirmationDialog(
            "Mover \(model.selectedCount) \(model.selectedCount == 1 ? "item" : "itens") para o Lixo?",
            isPresented: $showingTrashConfirmation
        ) {
            Button("Mover para o Lixo", role: .destructive) { model.trashSelected() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .alert("Resultado da limpeza", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .task {
            monitorModel.start()
            if model.report == nil { model.scan() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.accentColor)
                Text("Mac Superpowers")
                    .font(.headline)
            }
            .padding(.horizontal, 10)
            .padding(.top, 64)
            .padding(.bottom, 44)

            Text("LIMPEZA")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            ForEach(Destination.allCases, id: \.self) { item in
                if item == .disk {
                    Text("ANÁLISE")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 30)
                        .padding(.bottom, 10)
                }
                Button {
                    destination = item
                } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(.subheadline.weight(destination == item ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(destination == item ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .background(destination == item ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 4)
            }

            Spacer()
            Label("Análise local no seu Mac", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func mainContent(width: CGFloat) -> some View {
        let inset: CGFloat = width < 760 ? 24 : 40

        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 42) {
                    header
                    if let report = model.report {
                        summary(report)
                        if !report.issues.isEmpty { issueBanner(report.issues) }
                        if !visibleCandidates.isEmpty { results }
                        if !visibleSystemFindings.isEmpty { systemResults }
                    }
                }
                .frame(width: max(0, min(1040, width - inset * 2)), alignment: .leading)
                .padding(.horizontal, inset)
                .padding(.top, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            if model.selectedCount > 0 { selectionBar(compact: width < 880, inset: inset) }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 28) {
            HStack {
                Spacer()
                Button(action: model.scan) {
                    Label("Analisar novamente", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .disabled(model.isScanning || model.isTrashing)
                .help("Atualizar a análise")
            }
            VStack(spacing: 9) {
                Text(destination.rawValue)
                    .font(.largeTitle.bold())
                Text(destination.explanation)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 8)
    }

    private func summary(_ report: ScanReport) -> some View {
        let candidates = visibleCandidates
        let systemFindings = visibleSystemFindings
        let itemCount = candidates.count + systemFindings.count
        let totalSize = candidates.reduce(0) { $0 + $1.size } + systemFindings.reduce(0) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 20) {
                if itemCount == 0 {
                    Image("EmptyState-MacEmOrdem", bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 74, height: 64)
                } else {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(itemCount == 0 ? "Nada para revisar aqui" : "Análise concluída")
                        .font(.title2.bold())
                    Text(itemCount == 0
                         ? "Nenhum item desta seção foi encontrado nas áreas analisadas."
                         : "\(itemCount) \(itemCount == 1 ? "item" : "itens") para revisar")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if itemCount > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatSize(totalSize))
                            .font(.title.bold().monospacedDigit())
                        Text("identificados nesta seção")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if destination == .overview {
                VStack(spacing: 0) {
                    categorySummaryRow(.cache, report: report)
                    Divider().padding(.vertical, 12)
                    categorySummaryRow(.leftover, report: report)
                    Divider().padding(.vertical, 12)
                    systemSummaryRow(report.systemFindings)
                }
            }

            Text(destination == .overview
                 ? "\(report.ignoredInstalledCount) itens de apps instalados e \(report.unverifiedNameCount) nomes sem identificação confiável ficaram fora. Serviços e componentes exigem revisão separada."
                 : destination == .system
                    ? "Selecione apenas o que reconhece. Para componentes protegidos em /Library, o macOS pode pedir autorização de administrador."
                    : "A classificação usa o nome da pasta e os apps encontrados. Revise cada caminho antes de mover algo para o Lixo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(26)
        .appSurface()
    }

    private func systemSummaryRow(_ findings: [SystemFinding]) -> some View {
        Button {
            destination = .system
        } label: {
            HStack(spacing: 14) {
                Image(systemName: Destination.system.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Destination.system.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Inicialização e dados associados; revisão manual")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text("\(findings.count) \(findings.count == 1 ? "item" : "itens")")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func categorySummaryRow(_ category: CleanupCategory, report: ScanReport) -> some View {
        let entries = report.candidates.filter { $0.category == category }
        return Button {
            destination = destinationFor(category)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: category.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(category.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(entries.count) \(entries.count == 1 ? "item" : "itens")")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(formatSize(entries.reduce(0) { $0 + $1.size }))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func issueBanner(_ issues: [String]) -> some View {
        Label("Algumas áreas não puderam ser lidas (\(issues.count)). A análise pode estar incompleta.",
              systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface()
            .help(issues.joined(separator: "\n"))
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Itens para revisar")
                    .font(.title2.bold())
                Spacer()
                if !visibleCandidates.isEmpty {
                    Button {
                        toggleAllVisible()
                    } label: {
                        Label(allVisibleSelected ? "Desmarcar tudo" : "Selecionar tudo",
                              systemImage: allVisibleSelected ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(visibleCandidates.enumerated()), id: \.element.id) { index, candidate in
                    candidateRow(candidate)
                    if index < visibleCandidates.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .padding(.horizontal, 10)
            .appSurface()
        }
    }

    private var systemResults: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Serviços e componentes")
                    .font(.title2.bold())
                Spacer()
                Button {
                    let urls = visibleSystemFindings.map(\.url)
                    if allSystemSelected { model.deselectAll(urls) }
                    else { model.selectAll(urls) }
                } label: {
                    Label(allSystemSelected ? "Desmarcar tudo" : "Selecionar tudo",
                          systemImage: allSystemSelected ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(model.isTrashing)
            }
            Text("Serviços ligados a apps não encontrados, executáveis ausentes e dados associados. Revise cada caminho antes de mover ao Lixo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(visibleSystemFindings.enumerated()), id: \.element.id) { index, finding in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { model.selectedURLs.contains(finding.url) },
                            set: { _ in model.toggle(finding.url) }
                        ))
                        .labelsHidden()
                        .disabled(model.isTrashing)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(finding.title)
                                .font(.headline)
                            Text(finding.kind + " · revisão manual")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(finding.url.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(finding.url.path)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 8) {
                            Text(formatSize(finding.size))
                                .font(.headline.monospacedDigit())
                            Button("Mostrar no Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([finding.url])
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .font(.caption)
                        }
                    }
                    .padding(18)
                    if index < visibleSystemFindings.count - 1 { Divider().padding(.leading, 48) }
                }
            }
            .padding(.horizontal, 10)
            .appSurface()
        }
    }

    private func candidateRow(_ candidate: CleanupCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { model.selectedURLs.contains(candidate.url) },
                set: { _ in model.toggle(candidate.url) }
            ))
            .labelsHidden()
            .disabled(model.isTrashing)
            VStack(alignment: .leading, spacing: 6) {
                Text(candidate.name).font(.headline).lineLimit(1)
                Text("\(candidate.source.displayName) · \(candidate.source.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(candidate.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(candidate.url.path)
                Text(candidate.explanation)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Text(formatSize(candidate.size)).font(.headline.monospacedDigit())
                Button("Mostrar no Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .font(.caption)
            }
        }
        .padding(18)
    }

    private func selectionBar(compact: Bool, inset: CGFloat) -> some View {
        HStack(spacing: 14) {
            if compact {
                clearSelectionButton.labelStyle(.iconOnly)
            } else {
                clearSelectionButton
            }
            Spacer(minLength: 4)
            Button {
                showingSelectionDetails = true
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(compact
                         ? "\(model.selectedCount)/\(model.availableCount) · \(formatSize(model.selectedSize))"
                         : "\(model.selectedCount) de \(model.availableCount) selecionados · \(formatSize(model.selectedSize))")
                        .font(.headline)
                        .lineLimit(1)
                    if !compact {
                        Text(selectedNamesSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Ver o resumo dos itens selecionados")
            .popover(isPresented: $showingSelectionDetails, arrowEdge: .top) {
                selectionDetails
            }
            if compact {
                selectAllButton.labelStyle(.iconOnly)
                deleteButton
            } else {
                selectAllButton
                deleteButton
            }
        }
        .padding(16)
        .appSurface()
        .padding(.horizontal, inset)
        .padding(.bottom, 24)
    }

    private var selectedNamesSummary: String {
        let names = model.selectedItems.prefix(2).map(\.name)
        let remaining = model.selectedCount - names.count
        return names.joined(separator: " · ") + (remaining > 0 ? " · +\(remaining)" : "")
    }

    private var confirmationMessage: String {
        let paths = model.selectedItems.prefix(3).map(\.url.path).joined(separator: "\n")
        let remaining = model.selectedCount - min(3, model.selectedCount)
        let extra = remaining > 0 ? "\n… e mais \(remaining)" : ""
        let protectedCount = model.selectedSystemFindings.filter { $0.url.path.hasPrefix("/Library/") }.count
        let systemNote = protectedCount == 0 ? "" :
            "\n\(protectedCount) \(protectedCount == 1 ? "componente protegido" : "componentes protegidos") em /Library. O macOS pode pedir autorização de administrador para movê-los ao Lixo. Serviços em uso podem exigir reinício."
        return "Revise os caminhos:\n\(paths)\(extra)\(systemNote)"
    }

    private var selectionDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Seleção para o Lixo")
                .font(.headline)
            Text("\(model.selectedCount) itens · \(formatSize(model.selectedSize))")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.selectedItems.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(item.url.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(formatSize(item.size))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 9)
                        if index < model.selectedCount - 1 { Divider() }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(20)
        .frame(width: 500)
    }

    @ViewBuilder
    private var clearSelectionButton: some View {
        Button {
            model.selectedURLs = []
        } label: {
            Label("Limpar", systemImage: "xmark.circle")
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
        }
        .appSecondaryAction()
        .disabled(model.isTrashing)
    }

    private var selectAllButton: some View {
        Button(action: toggleAllVisible) {
            Label(allVisibleSelected ? "Desmarcar tudo" : "Selecionar tudo",
                  systemImage: allVisibleSelected ? "checkmark.circle.fill" : "checkmark.circle")
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
        }
        .appSecondaryAction()
        .disabled(visibleSelectionURLs.isEmpty || model.isTrashing)
    }

    private var deleteButton: some View {
        Button {
            showingTrashConfirmation = true
        } label: {
            Label("Mover ao Lixo", systemImage: "trash.fill")
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
        }
        .appPrimaryAction(tint: .red)
        .disabled(model.isTrashing || model.selectedCount == 0)
    }

    private func toggleAllVisible() {
        if allVisibleSelected { model.deselectAll(visibleSelectionURLs) }
        else { model.selectAll(visibleSelectionURLs) }
    }

    private func destinationFor(_ category: CleanupCategory) -> Destination {
        switch category {
        case .cache: .caches
        case .leftover: .leftovers
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
