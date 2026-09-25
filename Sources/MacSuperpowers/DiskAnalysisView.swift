import AppKit
import SwiftUI

struct DiskAnalysisView: View {
    @ObservedObject var model: DiskAnalysisViewModel
    let width: CGFloat
    @State private var selectedNode: DiskNode?
    @State private var hoveredNode: DiskNode?
    @State private var focusStack: [DiskNode] = []

    private var inset: CGFloat { width < 760 ? 24 : 40 }
    private var contentWidth: CGFloat { max(0, width - inset * 2) }
    private var layoutWidth: CGFloat { min(1040, contentWidth) }
    private var headerHeight: CGFloat { 96 }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(width: layoutWidth)
                .padding(.horizontal, inset)
                .frame(maxWidth: .infinity)
                .frame(height: headerHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let report = model.report {
                        mapSection(report)
                    } else if model.isLoadingCache {
                        ProgressView("Abrindo mapa salvo…")
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if model.isScanning {
                        scanningState
                    } else if !model.isScanning {
                        readyState
                    }
                }
                .frame(width: layoutWidth, alignment: .leading)
                .padding(.horizontal, inset)
                .padding(.top, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .task { model.start() }
        .onChange(of: model.report?.scannedAt) { _, _ in
            guard let report = model.report else { return }
            var currentLevel = report.entries
            var updatedFocus: [DiskNode] = []
            for focused in focusStack {
                guard let refreshed = currentLevel.first(where: {
                    $0.url.standardizedFileURL.path == focused.url.standardizedFileURL.path
                }) else { break }
                updatedFocus.append(refreshed)
                currentLevel = refreshed.children
            }
            focusStack = updatedFocus
            selectedNode = nil
            hoveredNode = nil
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Disco")
                    .font(.headline)
                HStack(spacing: 8) {
                    if model.isScanning {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.report == nil ? "Analisando /" : "\(model.scannedItems.formatted()) itens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if model.isScanning {
                        Button("Cancelar", action: model.cancelScan)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Button {
                            focusStack = []
                            selectedNode = nil
                            model.scanRoot()
                        } label: {
                            Label("Analisar novamente", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(model.isLoadingCache)
                    }
                }
                .font(.subheadline.weight(.medium))
            }
            .frame(height: 32)

            volumeSummary
                .padding(.top, 1)
                .padding(.bottom, 9)
        }
        .frame(maxWidth: .infinity)
    }

    private var volumeSummary: some View {
        let volume = model.volumeInfo
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(volume.name, systemImage: "internaldrive")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let capacity = volume.capacity {
                    Text(formatSize(capacity))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
            if let capacity = volume.capacity,
               let available = volume.available,
               capacity > 0 {
                let used = max(0, capacity - available)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.09))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geometry.size.width * min(1, CGFloat(used) / CGFloat(capacity)))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("\(formatSize(used)) usados")
                    Spacer()
                    Text("\(formatSize(available)) disponíveis")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("O macOS não informou a capacidade deste volume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "chart.pie")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Analisar o disco de inicialização")
                .font(.title2.bold())
            Text("A análise começa em / e percorre os arquivos que o macOS permite acessar.")
                .foregroundStyle(.secondary)
            Button(action: model.scanRoot) {
                Label("Analisar disco", systemImage: "arrow.clockwise")
            }
            .appPrimaryAction()
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface()
    }

    private var scanningState: some View {
        HStack(spacing: 22) {
            ProgressView()
                .controlSize(.large)
            VStack(alignment: .leading, spacing: 7) {
                Text("Analisando arquivos…")
                    .font(.title2.bold())
                Text("\(model.scannedItems.formatted()) itens verificados")
                    .foregroundStyle(.secondary)
                Text("Percorrendo /; a primeira análise pode levar alguns minutos.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface()
    }

    private func mapSection(_ report: DiskScanReport) -> some View {
        let entries = focusStack.last?.children ?? report.entries
        let total = focusStack.last?.size ?? report.scannedBytes
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mapa de espaço")
                    .font(.title2.bold())
                Spacer()
                Text("\(formatSize(total)) mapeados")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                if !focusStack.isEmpty {
                    Button(report.rootName) { focusStack = []; selectedNode = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    ForEach(Array(focusStack.enumerated()), id: \.element.id) { index, node in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button(node.name) {
                            focusStack = Array(focusStack.prefix(index + 1))
                            selectedNode = nil
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                } else {
                    Text("/")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.showingCachedReport
                     ? "Cache de \(report.scannedAt.formatted(date: .abbreviated, time: .shortened))"
                     : "Analisado em \(report.scannedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .lineLimit(1)

            if total == 0 {
                ContentUnavailableView(
                    "Nenhum arquivo encontrado",
                    systemImage: "externaldrive",
                    description: Text("Esta área está vazia ou não pôde ser lida.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if layoutWidth >= 600 {
                let chartWidth = min(320, (layoutWidth - 24) * 0.47)
                HStack(alignment: .top, spacing: 24) {
                    radialChart(report, entries: entries, total: total)
                        .frame(width: chartWidth)
                    directoryList(entries, total: total,
                                  fileCount: focusStack.last?.fileCount ?? report.scannedFiles,
                                  height: chartWidth)
                        .frame(width: layoutWidth - chartWidth - 24, height: chartWidth)
                }
            } else {
                let chartWidth = min(360, layoutWidth)
                VStack(spacing: 24) {
                    radialChart(report, entries: entries, total: total)
                        .frame(width: chartWidth)
                    directoryList(entries, total: total,
                                  fileCount: focusStack.last?.fileCount ?? report.scannedFiles,
                                  height: chartWidth)
                        .frame(height: chartWidth)
                }
                .frame(maxWidth: .infinity)
            }

            if let selectedNode {
                selectedDetails(selectedNode)
            }
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                Text("Mapa de / com tamanhos estimados. Arquivos pequenos são agrupados; fototecas protegidas, outros volumes e links simbólicos ficam fora. O uso do volume também inclui snapshots e áreas protegidas.")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            if report.unreadableAreas > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Análise parcial: \(report.unreadableAreas) áreas não puderam ser lidas. O Acesso Total ao Disco pode ampliar a cobertura.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("Abrir Acesso Total ao Disco") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .font(.caption)
            }
            if model.cacheUnavailable {
                Label("Não foi possível salvar o cache local.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func radialChart(
        _ report: DiskScanReport,
        entries: [DiskNode],
        total: Int64
    ) -> some View {
        let sectors = DiskSector.build(from: entries, total: total, rootGroup: nil)
        return GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            ZStack {
                ForEach(sectors) { sector in
                    let shape = DiskSectorShape(
                        startAngle: sector.startAngle,
                        endAngle: sector.endAngle,
                        innerRadius: sector.innerRadius,
                        outerRadius: sector.outerRadius
                    )
                    shape
                        .fill(sector.color)
                        .overlay {
                            if (hoveredNode?.url == sector.node?.url || selectedNode?.url == sector.node?.url),
                               sector.node != nil {
                                shape.stroke(Color.primary.opacity(0.8), lineWidth: 2)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                Circle()
                    .fill(.clear)
                    .contentShape(Circle())
                    .frame(width: diameter, height: diameter)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hoveredNode = DiskSector.hitTest(sectors, at: point, diameter: diameter)?.node
                        case .ended:
                            hoveredNode = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { tap in
                        if let node = DiskSector.hitTest(sectors, at: tap.location, diameter: diameter)?.node {
                            activate(node)
                        }
                    })
                    .accessibilityLabel("Mapa de espaço; use Maiores itens para navegar pelas pastas")
                Button {
                    if !focusStack.isEmpty { focusStack.removeLast(); selectedNode = nil }
                } label: {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: diameter * 0.27, height: diameter * 0.27)
                        VStack(spacing: 3) {
                            Text(formatSize(hoveredNode?.size ?? selectedNode?.size ?? total))
                                .font(.headline.monospacedDigit())
                            Text(hoveredNode?.name ?? selectedNode?.name ?? focusStack.last?.name ?? report.rootName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: diameter * 0.22)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(focusStack.isEmpty ? "Raiz do disco" : "Voltar à pasta anterior")
                .zIndex(1)
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func directoryList(_ entries: [DiskNode], total: Int64, fileCount: Int, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Maiores itens")
                .font(.headline)
                .padding(.bottom, 12)
            if entries.isEmpty {
                Text("Os \(fileCount.formatted()) arquivos desta pasta são pequenos e aparecem agrupados no mapa.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        let visibleEntries = Array(entries.prefix(100))
                        ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, node in
                            Button { activate(node) } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(node.isDirectory
                                              ? DiskSector.folderColor(group: index, depth: 0)
                                              : Color.secondary.opacity(0.55))
                                        .frame(width: 9, height: 9)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(node.name)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text("\(percent(node.size, of: total)) · \(node.fileCount.formatted()) \(node.fileCount == 1 ? "arquivo" : "arquivos")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 6)
                                    Text(formatSize(node.size))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                                .background((hoveredNode?.url == node.url || selectedNode?.url == node.url)
                                            ? Color.accentColor.opacity(0.10) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(node.name), \(formatSize(node.size))")
                            .onHover { hoveredNode = $0 ? node : nil }
                            if index < visibleEntries.count - 1 { Divider() }
                        }
                        if entries.count > visibleEntries.count {
                            Text("Mostrando os \(visibleEntries.count) maiores itens")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(height: height)
        .appSurface()
    }

    private func selectedDetails(_ node: DiskNode) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(Color.accentColor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name).font(.headline)
                Text("\(formatSize(node.size)) · \(node.fileCount.formatted()) \(node.fileCount == 1 ? "arquivo" : "arquivos")")
                    .foregroundStyle(.secondary)
                Text(node.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(node.url.path)
            }
            Spacer()
            Button("Mostrar no Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(20)
        .appSurface()
    }

    private func activate(_ node: DiskNode) {
        if node.isDirectory {
            focusStack.append(node)
            selectedNode = nil
            hoveredNode = nil
        } else {
            selectedNode = node
        }
    }

    private func percent(_ value: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0%" }
        let fraction = Double(value) / Double(total)
        if value > 0 && fraction < 0.005 { return "<1%" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private func formatSize(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct DiskSector: Identifiable {
    let id: String
    let node: DiskNode?
    let startAngle: Double
    let endAngle: Double
    let depth: Int
    let groupIndex: Int
    let isFile: Bool
    let isAggregate: Bool

    var innerRadius: CGFloat { [0.28, 0.43, 0.58, 0.73, 0.86][depth] }
    var outerRadius: CGFloat { [0.41, 0.56, 0.71, 0.84, 0.98][depth] }
    var color: Color {
        if isFile { return Color.secondary.opacity(isAggregate ? 0.25 : 0.60) }
        return Self.folderColor(group: groupIndex, depth: depth)
            .opacity(isAggregate ? 0.34 : 1)
    }

    static func folderColor(group: Int, depth: Int) -> Color {
        let hues = [0.58, 0.31, 0.10, 0.76, 0.48, 0.02, 0.88, 0.18, 0.66, 0.40, 0.95, 0.23]
        let hue = hues[group % hues.count]
        return Color(hue: hue,
                     saturation: max(0.48, 0.77 - Double(depth) * 0.055),
                     brightness: max(0.65, 0.96 - Double(depth) * 0.065))
    }

    static func hitTest(_ sectors: [DiskSector], at point: CGPoint, diameter: CGFloat) -> DiskSector? {
        guard diameter > 0 else { return nil }
        let center = diameter / 2
        let distance = hypot(point.x - center, point.y - center) / center
        let angle = (atan2(point.y - center, point.x - center) + .pi / 2 + .pi * 2)
            .truncatingRemainder(dividingBy: .pi * 2)
        return sectors.first {
            distance >= $0.innerRadius && distance <= $0.outerRadius &&
                angle >= $0.startAngle && angle <= $0.endAngle
        }
    }

    static func build(from entries: [DiskNode], total: Int64, rootGroup: Int?) -> [DiskSector] {
        var result: [DiskSector] = []
        append(entries, total: total, start: 0, sweep: .pi * 2,
               depth: 0, rootGroup: rootGroup, into: &result)
        return result
    }

    private static func append(
        _ entries: [DiskNode],
        total: Int64,
        start: Double,
        sweep: Double,
        depth: Int,
        rootGroup: Int?,
        into result: inout [DiskSector]
    ) {
        guard depth < 5, total > 0 else { return }
        let positive = entries.filter { $0.size > 0 }
        let limit = depth == 0 ? 12 : 8
        let minimumAngle = depth >= 3 ? 0.015 : 0.009
        let shown = Array(positive.prefix(limit).prefix {
            sweep * Double($0.size) / Double(total) >= minimumAngle
        })
        let hidden = positive.dropFirst(shown.count)
        let hiddenFolders = hidden.filter(\.isDirectory).reduce(Int64(0)) { $0 + $1.size }
        let visibleBytes = positive.reduce(Int64(0)) { $0 + $1.size }
        let hiddenFiles = max(0, total - visibleBytes)
            + hidden.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        var cursor = start

        for (index, node) in shown.enumerated() {
            let angle = sweep * Double(node.size) / Double(total)
            let group = rootGroup ?? index
            result.append(DiskSector(
                id: "\(depth):\(node.url.path)", node: node,
                startAngle: cursor, endAngle: cursor + angle,
                depth: depth, groupIndex: group,
                isFile: !node.isDirectory, isAggregate: false
            ))
            if node.isDirectory {
                // Ao focar uma pasta cujo único setor visível é outra pasta,
                // a primeira ramificação útil recebe uma paleta nova.
                let childGroup = rootGroup == nil && shown.count == 1 ? nil : group
                append(node.children, total: node.size, start: cursor, sweep: angle,
                       depth: depth + 1, rootGroup: childGroup, into: &result)
            }
            cursor += angle
        }
        if hiddenFolders > 0 {
            let angle = sweep * Double(hiddenFolders) / Double(total)
            result.append(DiskSector(
                id: "folders:\(depth):\(start)", node: nil,
                startAngle: cursor, endAngle: cursor + angle,
                depth: depth, groupIndex: rootGroup ?? 0,
                isFile: false, isAggregate: true
            ))
            cursor += angle
        }
        if hiddenFiles > 0 {
            result.append(DiskSector(
                id: "files:\(depth):\(start)", node: nil,
                startAngle: cursor, endAngle: start + sweep,
                depth: depth, groupIndex: rootGroup ?? 0,
                isFile: true, isAggregate: true
            ))
        }
    }
}

private struct DiskSectorShape: Shape {
    let startAngle: Double
    let endAngle: Double
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let gap = min(0.012, (endAngle - startAngle) * 0.12)
        let first = startAngle + gap / 2 - .pi / 2
        let last = endAngle - gap / 2 - .pi / 2
        let steps = max(2, Int((last - first) * 70))
        var path = Path()

        for step in 0...steps {
            let angle = first + (last - first) * Double(step) / Double(steps)
            let point = CGPoint(
                x: center.x + cos(angle) * radius * outerRadius,
                y: center.y + sin(angle) * radius * outerRadius
            )
            if step == 0 { path.move(to: point) }
            else { path.addLine(to: point) }
        }
        for step in (0...steps).reversed() {
            let angle = first + (last - first) * Double(step) / Double(steps)
            path.addLine(to: CGPoint(
                x: center.x + cos(angle) * radius * innerRadius,
                y: center.y + sin(angle) * radius * innerRadius
            ))
        }
        path.closeSubpath()
        return path
    }
}
