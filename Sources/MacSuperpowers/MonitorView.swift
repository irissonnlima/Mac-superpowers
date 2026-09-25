import AppKit
import Charts
import MonitorCore
import SwiftUI

struct MonitorView: View {
    @ObservedObject var model: MonitorViewModel
    let width: CGFloat
    @State private var showsSystemProcesses = false
    @State private var showsHistory = false
    @State private var selectedApp: MonitorAppTotal?
    @State private var showingEraseConfirmation = false

    private var inset: CGFloat { width < 760 ? 24 : 40 }
    private var canSplitCores: Bool {
        let names = model.snapshot?.performanceLevels.map { $0.name.lowercased() } ?? []
        return names.count == 2 && names.contains("efficiency")
            && (names.contains("performance") || names.contains("super"))
    }
    private var fastCoreName: String {
        model.snapshot?.performanceLevels.first(where: { $0.name.lowercased() != "efficiency" })?.name ?? "Desempenho"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, inset)
                .padding(.top, 24)
                .padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    categoryPicker
                    summary
                    if model.category == .thermal { thermalSensorSection }
                    chartSection
                    appSection
                    footer
                }
                .frame(maxWidth: 1050, alignment: .leading)
                .padding(.horizontal, inset)
                .padding(.bottom, 42)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
        .sheet(item: $selectedApp) { app in appDetail(app) }
        .confirmationDialog("Apagar todo o histórico do Monitor?", isPresented: $showingEraseConfirmation) {
            Button("Apagar histórico", role: .destructive) { model.eraseHistory() }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("As medições salvas neste Mac serão removidas. A coleta atual continuará.") }
        .alert("Monitor", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }
        )) { Button("OK", role: .cancel) { model.notice = nil } }
        message: { Text(model.notice ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Monitor")
                        .font(.largeTitle.bold())
                    HStack(spacing: 7) {
                        Circle().fill(model.backgroundActive ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(model.dataStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 7) {
                    Toggle("Coletar em segundo plano", isOn: Binding(
                        get: { model.backgroundActive || model.backgroundPending },
                        set: { model.setBackgroundEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .font(.caption)
                    if let date = model.snapshot?.date {
                        Text("Atualizado às \(date.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Picker("Período", selection: $model.range) {
                    ForEach(MonitorRange.allCases) { range in Text(range.rawValue).tag(range) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)
                Spacer()
                Button {
                    showsHistory.toggle()
                } label: {
                    Label(showsHistory ? "Ver agora" : "Ver histórico", systemImage: showsHistory ? "waveform.path" : "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var categoryPicker: some View {
        HStack(spacing: 5) {
            ForEach(MonitorCategory.allCases.filter { $0 != .battery || model.hasBattery }) { category in
                Button {
                    model.category = category
                } label: {
                    Label(category.rawValue, systemImage: category.symbol)
                        .font(.subheadline.weight(model.category == category ? .semibold : .regular))
                        .foregroundStyle(model.category == category ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(model.category == category ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            summaryValue("CPU", value: model.interval?.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—",
                         detail: "do Mac")
            Divider().frame(height: 42)
            summaryValue("Memória", value: bytes(model.snapshot?.usedMemoryBytes ?? 0),
                         detail: "de \(bytes(model.snapshot?.physicalBytes ?? 0))")
            Divider().frame(height: 42)
            summaryValue("Disco livre", value: bytes(model.snapshot?.diskFreeBytes ?? 0),
                         detail: "volume de inicialização")
            Divider().frame(height: 42)
            summaryValue(model.category == .thermal ? "Temperatura" : (model.hasBattery ? "Bateria" : "Térmico"),
                         value: model.category == .thermal ? selectedTemperatureValue
                            : (model.hasBattery ? batteryValue : thermalName(model.snapshot?.thermalState ?? 0)),
                         detail: model.category == .thermal ? "sensor selecionado"
                            : (model.hasBattery ? (model.snapshot?.onBattery == true ? "descarregando" : "na tomada") : "estado do sistema"))
        }
        .padding(.vertical, 18)
        .appSurface()
    }

    private func summaryValue(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).contentTransition(.numericText())
            Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private var batteryValue: String {
        guard let value = model.snapshot?.batteryPercent else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private var selectedTemperatureValue: String {
        guard let sensor = model.snapshot?.temperatures.first(where: { $0.id == model.selectedTemperatureSensorID }) else { return "—" }
        return "\(sensor.celsius.formatted(.number.precision(.fractionLength(1)))) °C"
    }

    private var thermalSensorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sensores de temperatura").font(.title3.bold())
                Spacer()
                Text("\(model.snapshot?.temperatures.count ?? 0) disponíveis")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "thermometer.medium").foregroundStyle(Color.accentColor)
                Text("Estado térmico do macOS: \(thermalName(model.snapshot?.thermalState ?? -1))")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            Text("Leituras reais em °C, atualizadas a cada minuto. Os sensores variam por modelo e versão do macOS; códigos do hardware aparecem abaixo.")
                .font(.caption).foregroundStyle(.secondary)
            let sensors = model.snapshot?.temperatures ?? []
            if sensors.isEmpty {
                ContentUnavailableView("Temperaturas indisponíveis", systemImage: "thermometer.medium",
                                       description: Text("Este Mac não expôs sensores de temperatura legíveis. O estado térmico do macOS continua disponível."))
                    .frame(height: 150)
            } else {
                ForEach(thermalGroups, id: \.self) { group in
                    let items = sensors.filter { thermalGroup($0.id) == group }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(group).font(.subheadline.weight(.semibold))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 9)], spacing: 9) {
                                ForEach(items) { sensor in
                                    Button { model.selectedTemperatureSensorID = sensor.id } label: {
                                        HStack(spacing: 10) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(thermalLabel(sensor.id))
                                                    .font(.subheadline.weight(.medium)).lineLimit(1)
                                                Text(sensor.id).font(.caption2.monospaced())
                                                    .foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 4)
                                            Text("\(sensor.celsius.formatted(.number.precision(.fractionLength(1)))) °C")
                                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                        }
                                        .padding(12)
                                        .background(model.selectedTemperatureSensorID == sensor.id
                                                    ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.045),
                                                    in: RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .appSurface()
    }

    private var thermalGroups: [String] {
        ["CPU", "GPU", "Memória", "Armazenamento", "Bateria", "SoC e alimentação", "Outros sensores"]
    }

    private func thermalGroup(_ identifier: String) -> String {
        if identifier == "Battery:Pack" || identifier.hasPrefix("SMC:TB") { return "Bateria" }
        if identifier.hasPrefix("HID:gas gauge battery") { return "Bateria" }
        if identifier.hasPrefix("HID:NAND") { return "Armazenamento" }
        guard identifier.hasPrefix("SMC:") else { return "SoC e alimentação" }
        let key = String(identifier.dropFirst(4))
        if key.hasPrefix("TC") || key.hasPrefix("Tp") || key.hasPrefix("Te") { return "CPU" }
        if key.hasPrefix("TG") || key.hasPrefix("Tg") || key.hasPrefix("TRD") { return "GPU" }
        if ["TVm", "Tm0", "TMVR"].contains(where: key.hasPrefix) { return "Memória" }
        if ["T5", "Ts1", "TH0"].contains(where: key.hasPrefix) { return "Armazenamento" }
        if ["TP", "Ts0", "TV", "TA", "TW", "TI", "TD"].contains(where: key.hasPrefix) { return "SoC e alimentação" }
        return "Outros sensores"
    }

    private func thermalLabel(_ identifier: String) -> String {
        switch identifier {
        case "SMC:TCMz": return "Ponto mais quente da CPU"
        case "SMC:TCMb": return "Máximo da CPU"
        case "SMC:TRDX": return "Ponto mais quente da GPU"
        case "Battery:Pack": return "Conjunto da bateria"
        default:
            if identifier.hasPrefix("SMC:TB") { return "Bateria · \(identifier.dropFirst(4))" }
            if identifier.hasPrefix("HID:") { return String(identifier.dropFirst(4)) }
            return "Sensor \(identifier.dropFirst(4))"
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chartTitle).font(.title3.bold())
                    Text(chartExplanation).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.category == .cpu, let levels = model.snapshot?.performanceLevels, !levels.isEmpty {
                    Text(levels.map { "\($0.name) \($0.logicalCores)" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.category == .thermal, model.selectedTemperatureSensorID != nil,
               model.temperaturePoints.isEmpty {
                ContentUnavailableView("Aguardando histórico", systemImage: "chart.xyaxis.line",
                                       description: Text("A primeira leitura deste sensor aparecerá após a coleta em segundo plano."))
                    .frame(height: 210)
            } else if model.points.isEmpty && (model.category != .thermal || model.temperaturePoints.isEmpty) {
                ContentUnavailableView("Aguardando medições", systemImage: "chart.xyaxis.line",
                                       description: Text("O gráfico começará após as primeiras amostras."))
                    .frame(height: 210)
            } else {
                chart
                    .frame(height: 230)
                    .chartXScale(domain: Date().addingTimeInterval(-model.range.duration)...Date())
            }
            if model.category == .cpu, canSplitCores,
               model.points.contains(where: { $0.performanceCoreEquivalents != nil }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Processos observados por tipo de núcleo")
                        .font(.subheadline.weight(.semibold))
                    Text("Núcleos equivalentes em uso · \(fastCoreName) (cor de destaque) · Efficiency (tracejado). Processos protegidos podem ficar fora.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart {
                        ForEach(model.points) { point in
                            if let value = point.performanceCoreEquivalents {
                                LineMark(x: .value("Hora", point.date), y: .value("Núcleos", value),
                                         series: .value("Tipo", fastCoreName))
                                    .foregroundStyle(Color.accentColor)
                            }
                            if let value = point.efficiencyCoreEquivalents {
                                LineMark(x: .value("Hora", point.date), y: .value("Núcleos", value),
                                         series: .value("Tipo", "Efficiency"))
                                    .foregroundStyle(Color.secondary)
                                    .lineStyle(StrokeStyle(dash: [5, 4]))
                            }
                        }
                    }
                    .frame(height: 115)
                    .chartXScale(domain: Date().addingTimeInterval(-model.range.duration)...Date())
                }
                .padding(.top, 10)
            }
        }
        .padding(20)
        .appSurface()
    }

    @ViewBuilder
    private var chart: some View {
        switch model.category {
        case .cpu:
            Chart(model.points.compactMap { point -> (Date, Double)? in
                point.cpuPercent.map { (point.date, $0) }
            }, id: \.0) { point in
                AreaMark(x: .value("Hora", point.0), y: .value("CPU", point.1))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                LineMark(x: .value("Hora", point.0), y: .value("CPU", point.1))
                    .foregroundStyle(Color.accentColor)
            }
            .chartYScale(domain: 0...100)
        case .memory:
            Chart(model.points) { point in
                AreaMark(x: .value("Hora", point.date), y: .value("GB", Double(point.usedMemoryBytes) / 1e9))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                LineMark(x: .value("Hora", point.date), y: .value("GB", Double(point.usedMemoryBytes) / 1e9))
                    .foregroundStyle(Color.accentColor)
            }
        case .disk:
            Chart {
                ForEach(model.points) { point in
                    LineMark(x: .value("Hora", point.date), y: .value("MB/s", point.readBytesPerSecond / 1e6),
                             series: .value("Fluxo", "Leitura"))
                        .foregroundStyle(Color.accentColor)
                    LineMark(x: .value("Hora", point.date), y: .value("MB/s", point.writtenBytesPerSecond / 1e6),
                             series: .value("Fluxo", "Gravação"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(dash: [5, 4]))
                }
            }
        case .battery:
            Chart(model.points.filter { $0.batteryPercent != nil }) { point in
                LineMark(x: .value("Hora", point.date), y: .value("Carga", point.batteryPercent ?? 0))
                    .foregroundStyle(Color.accentColor)
            }
            .chartYScale(domain: 0...100)
        case .thermal:
            if model.selectedTemperatureSensorID != nil {
                Chart(model.temperaturePoints) { point in
                    LineMark(x: .value("Hora", point.date), y: .value("°C", point.celsius))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("Hora", point.date), y: .value("°C", point.celsius))
                        .foregroundStyle(Color.accentColor)
                }
            } else {
                Chart(model.points) { point in
                    LineMark(x: .value("Hora", point.date), y: .value("Estado", point.thermalState))
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.stepEnd)
                }
                .chartYScale(domain: 0...3)
            }
        }
    }

    private var chartTitle: String {
        switch model.category {
        case .cpu: "Uso total de CPU"
        case .memory: "Memória em uso"
        case .disk: "Atividade de leitura e gravação"
        case .battery: "Carga da bateria"
        case .thermal: model.selectedTemperatureSensorID.map { "Histórico · \(thermalLabel($0))" } ?? "Estado térmico"
        }
    }

    private var chartExplanation: String {
        switch model.category {
        case .cpu: "Porcentagem da capacidade de todos os núcleos lógicos."
        case .memory: "Memória física usada, aproximada; não é a soma dos processos."
        case .disk: "MB/s de processos observados; áreas protegidas podem ficar fora."
        case .battery: "Carga medida; intervalos sem coleta não representam carga zero."
        case .thermal: model.selectedTemperatureSensorID == nil
            ? "Estado térmico do macOS: 0 normal · 1 elevado · 2 alto · 3 crítico."
            : "Temperatura do sensor selecionado em °C. O histórico guarda uma leitura a cada 5 minutos."
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(showsHistory ? "Apps no período" : "Apps agora")
                        .font(.title3.bold())
                    Text(listExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Incluir sistema", isOn: $showsSystemProcesses)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            VStack(spacing: 0) {
                if showsHistory {
                    let items = sortedTotals
                    if items.isEmpty { emptyList }
                    ForEach(Array(items.prefix(50).enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.leading, 50) }
                        Button { selectedApp = app } label: {
                            appRow(name: app.name, key: app.id, value: historicValue(app), detail: historicDetail(app))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    let items = sortedLive
                    if items.isEmpty { emptyList }
                    ForEach(Array(items.prefix(50).enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.leading, 50) }
                        appRow(name: app.name, key: app.id, value: liveValue(app), detail: liveDetail(app))
                    }
                }
            }
            .appSurface()
        }
    }

    private var emptyList: some View {
        Text("Aguardando dados de processos acessíveis neste período.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
    }

    private func appRow(name: String, key: String, value: String, detail: String) -> some View {
        HStack(spacing: 12) {
            appIcon(key)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
            if showsHistory { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func appIcon(_ key: String) -> some View {
        if !key.hasPrefix("process:"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().scaledToFit()
        } else {
            Image(systemName: "app.dashed")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var sortedLive: [MonitorAppActivity] {
        model.liveApps.filter { showsSystemProcesses || !$0.isSystem }.sorted {
            switch model.category {
            case .cpu, .thermal: $0.cpuSeconds > $1.cpuSeconds
            case .memory: $0.physicalBytes > $1.physicalBytes
            case .disk: $0.readBytes + $0.writtenBytes > $1.readBytes + $1.writtenBytes
            case .battery: $0.cpuEnergyJoules > $1.cpuEnergyJoules
            }
        }
    }

    private var sortedTotals: [MonitorAppTotal] {
        model.totals.filter { showsSystemProcesses || !$0.isSystem }.sorted {
            switch model.category {
            case .cpu, .thermal: $0.cpuSeconds > $1.cpuSeconds
            case .memory: $0.averageMemoryBytes > $1.averageMemoryBytes
            case .disk: $0.readBytes + $0.writtenBytes > $1.readBytes + $1.writtenBytes
            case .battery: ($0.onBatteryCPUEnergyJoules ?? $0.onBatteryCPUSeconds) > ($1.onBatteryCPUEnergyJoules ?? $1.onBatteryCPUSeconds)
            }
        }
    }

    private var listExplanation: String {
        switch model.category {
        case .cpu: showsHistory ? "Tempo de núcleo acumulado; 1 core-h = 1 núcleo usado por 1 hora." : "100% equivale a um núcleo lógico ocupado."
        case .memory: showsHistory ? "Média de memória física observada; toque para ver o pico." : "Pegada física dos processos do app, que não soma exatamente ao total do Mac."
        case .disk: showsHistory ? "Bytes lidos e escritos no período." : "Atividade entre as duas últimas amostras."
        case .battery: "Atividade medida enquanto a bateria descarregava; não prova a causa da descarga."
        case .thermal: "Apps mais ativos no período; atividade simultânea não prova causa do calor."
        }
    }

    private func liveValue(_ app: MonitorAppActivity) -> String {
        switch model.category {
        case .cpu, .thermal: "\(Int((100 * app.cpuSeconds / max(0.1, model.interval?.elapsed ?? 1)).rounded()))%"
        case .memory: bytes(app.physicalBytes)
        case .disk: "\(bytes(app.readBytes + app.writtenBytes)) / amostra"
        case .battery: model.snapshot?.onBattery == true && app.energyAvailable
            ? "\(app.cpuEnergyJoules.formatted(.number.precision(.fractionLength(2)))) J" : "—"
        }
    }

    private func liveDetail(_ app: MonitorAppActivity) -> String {
        if model.category == .cpu, canSplitCores, app.performanceTimeAvailable {
            return "\(fastCoreName) \(app.performanceCPUSeconds.formatted(.number.precision(.fractionLength(2))))s · Efficiency \(max(0, app.cpuSeconds - app.performanceCPUSeconds).formatted(.number.precision(.fractionLength(2))))s nesta amostra"
        }
        return "\(app.observedProcessCount) \(app.observedProcessCount == 1 ? "processo" : "processos") observado(s)"
    }

    private func historicValue(_ app: MonitorAppTotal) -> String {
        switch model.category {
        case .cpu, .thermal: "\((app.cpuSeconds / 3600).formatted(.number.precision(.fractionLength(2)))) core-h"
        case .memory: bytes(UInt64(max(0, app.averageMemoryBytes)))
        case .disk: bytes(app.readBytes + app.writtenBytes)
        case .battery: app.onBatteryCPUEnergyJoules.map { "\($0.formatted(.number.precision(.fractionLength(1)))) J" }
            ?? "\((app.onBatteryCPUSeconds / 3600).formatted(.number.precision(.fractionLength(2)))) core-h"
        }
    }

    private func historicDetail(_ app: MonitorAppTotal) -> String {
        switch model.category {
        case .cpu where canSplitCores && app.performanceCPUSeconds != nil:
            let p = app.performanceCPUSeconds ?? 0
            return "\(fastCoreName) \((p / 3600).formatted(.number.precision(.fractionLength(2)))) · Efficiency \((max(0, app.cpuSeconds - p) / 3600).formatted(.number.precision(.fractionLength(2)))) core-h"
        case .memory: return "Pico \(bytes(app.peakMemoryBytes))"
        case .disk: return "Leitura \(bytes(app.readBytes)) · gravação \(bytes(app.writtenBytes))"
        case .battery: return "Durante a descarga · \((app.onBatteryCPUSeconds / 3600).formatted(.number.precision(.fractionLength(2)))) core-h de CPU"
        default: return "Acumulado no período selecionado"
        }
    }

    private var footer: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cobertura da última amostra: \(Int(((model.interval?.coverage ?? 0) * 100).rounded()))% dos processos listados")
                Text("Processos protegidos e os que terminam entre amostras podem ficar fora. Pausas de coleta não são tratadas como zero.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Apagar histórico") { showingEraseConfirmation = true }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func appDetail(_ app: MonitorAppTotal) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                appIcon(app.id).frame(width: 40, height: 40)
                VStack(alignment: .leading) {
                    Text(app.name).font(.title2.bold())
                    Text(app.id).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            LabeledContent("CPU acumulada", value: "\((app.cpuSeconds / 3600).formatted(.number.precision(.fractionLength(2)))) core-h")
            if canSplitCores, let p = app.performanceCPUSeconds {
                LabeledContent("Núcleos \(fastCoreName)", value: "\((p / 3600).formatted(.number.precision(.fractionLength(2)))) core-h")
                LabeledContent("Núcleos de eficiência", value: "\((max(0, app.cpuSeconds - p) / 3600).formatted(.number.precision(.fractionLength(2)))) core-h")
            }
            LabeledContent("Memória média observada", value: bytes(UInt64(max(0, app.averageMemoryBytes))))
            LabeledContent("Pico de memória", value: bytes(app.peakMemoryBytes))
            LabeledContent("Leitura / gravação", value: "\(bytes(app.readBytes)) / \(bytes(app.writtenBytes))")
            if let energy = app.cpuEnergyJoules {
                LabeledContent("Energia de CPU", value: "\(energy.formatted(.number.precision(.fractionLength(2)))) J")
            }
            LabeledContent("CPU durante a descarga", value: "\((app.onBatteryCPUSeconds / 3600).formatted(.number.precision(.fractionLength(2)))) core-h")
            Text("Valores coletados localmente no período selecionado. Energia de CPU não equivale ao consumo total da bateria.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(minWidth: 440, minHeight: 350)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private func thermalName(_ value: Int) -> String {
        switch value {
        case 0: "Normal"
        case 1: "Elevado"
        case 2: "Alto"
        case 3: "Crítico"
        default: "Indisponível"
        }
    }
}
