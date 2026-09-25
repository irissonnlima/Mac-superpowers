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
    @State private var selectedThermalGroup = "CPU"

    private var inset: CGFloat { width < 760 ? 24 : 40 }
    private var usesSideBySidePanels: Bool { width >= 620 }
    private var panelHeight: CGFloat {
        switch model.category {
        case .battery: 620
        case .cpu: 525
        default: 450
        }
    }
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
                    summary
                    categoryPicker
                    comparisonSection
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
                        .background(model.category == category ? Color.primary.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
                            : (model.hasBattery ? batterySummaryDetail : "estado do sistema"))
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

    private var batterySummaryDetail: String {
        if model.snapshot?.onBattery == true { return "descarregando" }
        if let watts = model.snapshot?.inputPowerWatts { return "\(wattsText(watts)) da fonte" }
        return "na tomada"
    }

    private var selectedTemperatureValue: String {
        guard let sensor = model.snapshot?.temperatures.first(where: { $0.id == model.selectedTemperatureSensorID }) else { return "—" }
        return "\(sensor.celsius.formatted(.number.precision(.fractionLength(1)))) °C"
    }

    private var thermalSensorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sensores").font(.title3.bold())
                Spacer()
                Text("\(thermalComponents.reduce(0) { $0 + $1.sensorIDs.count })")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Mínimo, média e máximo no período · °C")
                .font(.caption).foregroundStyle(.secondary)
            Label("Estado do Mac: \(thermalName(model.snapshot?.thermalState ?? -1))", systemImage: "thermometer.medium")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            if !thermalComponents.isEmpty {
                Picker("Componente", selection: Binding(
                    get: { selectedThermalComponent?.name ?? selectedThermalGroup },
                    set: { selectThermalComponent($0) }
                )) {
                    ForEach(thermalComponents) { component in
                        Text("\(component.name) · \(component.sensorIDs.count)").tag(component.name)
                    }
                }
                .pickerStyle(.menu)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if thermalComponents.isEmpty {
                        ContentUnavailableView("Temperaturas indisponíveis", systemImage: "thermometer.medium",
                                               description: Text("Este Mac não expôs sensores de temperatura legíveis."))
                    }
                    if let component = selectedThermalComponent {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(component.name).font(.subheadline.weight(.semibold))
                            if let minimum = component.minimumCelsius,
                               let average = component.averageCelsius,
                               let maximum = component.maximumCelsius {
                                HStack(spacing: 6) {
                                    thermalStatistic("Mín", value: minimum)
                                    thermalStatistic("Média", value: average)
                                    thermalStatistic("Máx", value: maximum)
                                }
                            } else {
                                Text("Sem histórico neste período")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            ForEach(component.sensorIDs, id: \.self) { identifier in
                                Button { model.selectedTemperatureSensorID = identifier } label: {
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(thermalLabel(identifier))
                                                .font(.caption.weight(.medium)).lineLimit(1)
                                            Text(identifier).font(.caption2.monospaced())
                                                .foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                        Text(temperatureText(model.snapshot?.temperatures.first(where: { $0.id == identifier })?.celsius))
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(model.selectedTemperatureSensorID == identifier
                                                ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.045),
                                                in: RoundedRectangle(cornerRadius: 9))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: panelHeight, alignment: .top)
        .appSurface()
    }

    private func thermalStatistic(_ label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(temperatureText(value)).font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func temperatureText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) °C"
    }

    private struct ThermalComponent: Identifiable {
        let name: String
        let sensorIDs: [String]
        let minimumCelsius: Double?
        let averageCelsius: Double?
        let maximumCelsius: Double?
        var id: String { name }
    }

    private var thermalComponents: [ThermalComponent] {
        let identifiers = Set((model.snapshot?.temperatures ?? []).map(\.id))
            .union(model.temperatureStatistics.map(\.id))
        return thermalGroups.compactMap { group in
            let sensorIDs = identifiers.filter { thermalGroup($0) == group }.sorted()
            guard !sensorIDs.isEmpty else { return nil }
            let readings = model.temperatureStatistics.filter { thermalGroup($0.id) == group }
            let count = readings.reduce(0) { $0 + $1.sampleCount }
            return ThermalComponent(
                name: group, sensorIDs: sensorIDs,
                minimumCelsius: readings.map(\.minimumCelsius).min(),
                averageCelsius: count > 0
                    ? readings.reduce(0) { $0 + $1.averageCelsius * Double($1.sampleCount) } / Double(count) : nil,
                maximumCelsius: readings.map(\.maximumCelsius).max())
        }
    }

    private var selectedThermalComponent: ThermalComponent? {
        thermalComponents.first(where: { $0.name == selectedThermalGroup }) ?? thermalComponents.first
    }

    private func selectThermalComponent(_ group: String) {
        selectedThermalGroup = group
        guard let component = thermalComponents.first(where: { $0.name == group }),
              !component.sensorIDs.contains(model.selectedTemperatureSensorID ?? "") else { return }
        let preferred: [String]
        switch group {
        case "CPU": preferred = ["SMC:TCMz", "SMC:TCMb"]
        case "GPU": preferred = ["SMC:TRDX"]
        case "Bateria": preferred = ["Battery:Pack"]
        default: preferred = []
        }
        model.selectedTemperatureSensorID = preferred.first(where: component.sensorIDs.contains)
            ?? component.sensorIDs.first
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
            VStack(alignment: .leading, spacing: 4) {
                Text(chartTitle).font(.title3.bold())
                Text(chartExplanation).font(.caption).foregroundStyle(.secondary)
                if model.category == .cpu, let levels = model.snapshot?.performanceLevels, !levels.isEmpty {
                    Text(levels.map { "\($0.name) \($0.logicalCores)" }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if model.category == .battery { batteryLivePowerSection }
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
                    .frame(height: model.category == .battery ? 180 : 230)
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
            if model.category == .battery { batteryPowerHistorySection }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: panelHeight, alignment: .top)
        .appSurface()
    }

    @ViewBuilder
    private var comparisonSection: some View {
        if usesSideBySidePanels {
            HStack(alignment: .top, spacing: 16) {
                chartSection.frame(maxWidth: .infinity)
                secondarySection.frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 16) {
                chartSection
                secondarySection
            }
        }
    }

    @ViewBuilder
    private var secondarySection: some View {
        if model.category == .thermal { thermalSensorSection }
        else { appSection }
    }

    private var batteryLivePowerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text("Potência agora").font(.subheadline.weight(.semibold))
            if model.snapshot?.onBattery == false {
                powerRow("Da fonte", wattsText(model.snapshot?.inputPowerWatts), prominent: true)
                powerRow("Consumo do Mac", wattsText(model.snapshot?.systemLoadWatts))
                powerRow("Carga da bateria", batteryPowerValue)
                if let watts = model.snapshot?.adapterRatedWatts {
                    Text("Fonte: até \(watts) W de capacidade nominal")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(model.snapshot?.inputPowerWatts == nil
                     ? "Potência de entrada indisponível neste Mac."
                     : "Potência medida na entrada do Mac; a leitura do controlador pode demorar a atualizar.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                powerRow("Bateria para o Mac", batteryPowerValue, prominent: true)
                Text(batteryPowerExplanation).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var batteryPowerHistorySection: some View {
        if model.snapshot?.onBattery == false,
           model.externalPowerPoints.contains(where: { $0.inputWatts != nil }) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Histórico · entrada e consumo do Mac")
                    .font(.caption2).foregroundStyle(.secondary)
                Chart {
                    ForEach(model.externalPowerPoints) { point in
                        if let watts = point.inputWatts {
                            LineMark(x: .value("Hora", point.date), y: .value("W", watts),
                                     series: .value("Fluxo", "Entrada"))
                                .foregroundStyle(Color.accentColor)
                        }
                        if let watts = point.systemLoadWatts {
                            LineMark(x: .value("Hora", point.date), y: .value("W", watts),
                                     series: .value("Fluxo", "Mac"))
                                .foregroundStyle(Color.secondary)
                                .lineStyle(StrokeStyle(dash: [4, 3]))
                        }
                    }
                }
                .frame(height: 75)
                .chartXScale(domain: Date().addingTimeInterval(-model.range.duration)...Date())
            }
        } else if model.snapshot?.onBattery != false,
               model.points.contains(where: { $0.batteryPowerWatts != nil }) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Histórico · carga e descarga da bateria")
                    .font(.caption2).foregroundStyle(.secondary)
                Chart(model.points.compactMap { point -> (Date, Double)? in
                    point.batteryPowerWatts.map { (point.date, $0) }
                }, id: \.0) { point in
                    LineMark(x: .value("Hora", point.0), y: .value("W", point.1))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(height: 75)
                .chartXScale(domain: Date().addingTimeInterval(-model.range.duration)...Date())
            }
        }
    }

    private func powerRow(_ label: String, _ value: String, prominent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(prominent ? .subheadline.weight(.semibold) : .subheadline)
            Spacer(minLength: 4)
            Text(value).font(prominent ? .headline.monospacedDigit() : .subheadline.monospacedDigit())
                .lineLimit(1)
        }
    }

    private func wattsText(_ watts: Double?) -> String {
        guard let watts else { return "—" }
        return "\(watts.formatted(.number.precision(.fractionLength(1)))) W"
    }

    private var batteryPowerValue: String {
        guard let watts = model.snapshot?.batteryPowerWatts else { return "—" }
        return wattsText(abs(watts))
    }

    private var batteryPowerExplanation: String {
        guard let snapshot = model.snapshot, let watts = snapshot.batteryPowerWatts else {
            return "Este Mac não disponibilizou uma leitura de potência da bateria."
        }
        if watts > 0.1 { return "Entrando na bateria · potência aproximada de carga." }
        if watts < -0.1 { return "Saindo da bateria · potência aproximada de descarga." }
        return snapshot.onBattery ? "Sem fluxo mensurável nesta amostra." : "Bateria sem carga ou descarga mensurável nesta amostra."
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
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(showsHistory ? "Processos no período" : "Processos agora")
                        .font(.title3.bold())
                    Spacer(minLength: 4)
                    Toggle("Sistema", isOn: $showsSystemProcesses)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Incluir processos do sistema")
                }
                Text(listExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            ScrollView {
                LazyVStack(spacing: 0) {
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
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: panelHeight, alignment: .top)
        .appSurface()
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
            case .battery: ($0.energyAvailable ? $0.cpuEnergyJoules : $0.cpuSeconds)
                > ($1.energyAvailable ? $1.cpuEnergyJoules : $1.cpuSeconds)
            }
        }
    }

    private var sortedTotals: [MonitorAppTotal] {
        model.totals.filter { showsSystemProcesses || !$0.isSystem }.sorted {
            switch model.category {
            case .cpu, .thermal: $0.cpuSeconds > $1.cpuSeconds
            case .memory: $0.averageMemoryBytes > $1.averageMemoryBytes
            case .disk: $0.readBytes + $0.writtenBytes > $1.readBytes + $1.writtenBytes
        case .battery: ($0.cpuEnergyJoules ?? $0.cpuSeconds) > ($1.cpuEnergyJoules ?? $1.cpuSeconds)
            }
        }
    }

    private var listExplanation: String {
        switch model.category {
        case .cpu: showsHistory ? "Tempo de núcleo acumulado; 1 core-h = 1 núcleo usado por 1 hora." : "100% equivale a um núcleo lógico ocupado."
        case .memory: showsHistory ? "Média física observada; toque para ver o pico." : "Pegada física e parcela da RAM do Mac."
        case .disk: showsHistory ? "Bytes lidos e escritos no período." : "Leitura e gravação por segundo na última amostra."
        case .battery: showsHistory ? "Energia de CPU observada; não equivale ao gasto total do app." : "Potência de CPU quando disponível; caso contrário, uso de CPU."
        case .thermal: "Apps mais ativos no período; atividade simultânea não prova causa do calor."
        }
    }

    private func liveValue(_ app: MonitorAppActivity) -> String {
        switch model.category {
        case .cpu, .thermal: "\(Int((100 * app.cpuSeconds / max(0.1, model.interval?.elapsed ?? 1)).rounded()))%"
        case .memory: "\(bytes(app.physicalBytes)) · \(memoryPercent(Double(app.physicalBytes)))"
        case .disk: "\(bytes(UInt64(Double(app.readBytes + app.writtenBytes) / max(0.1, model.interval?.elapsed ?? 1))))/s"
        case .battery: app.energyAvailable
            ? "\((app.cpuEnergyJoules / max(0.1, model.interval?.elapsed ?? 1)).formatted(.number.precision(.fractionLength(2)))) W"
            : "\(Int((100 * app.cpuSeconds / max(0.1, model.interval?.elapsed ?? 1)).rounded()))% CPU"
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
        case .memory: "\(bytes(UInt64(max(0, app.averageMemoryBytes)))) · \(memoryPercent(app.averageMemoryBytes))"
        case .disk: bytes(app.readBytes + app.writtenBytes)
        case .battery: app.cpuEnergyJoules.map { "\($0.formatted(.number.precision(.fractionLength(1)))) J" }
            ?? "\((app.cpuSeconds / 3600).formatted(.number.precision(.fractionLength(2)))) core-h"
        }
    }

    private func historicDetail(_ app: MonitorAppTotal) -> String {
        switch model.category {
        case .cpu where canSplitCores && app.performanceCPUSeconds != nil:
            let p = app.performanceCPUSeconds ?? 0
            return "\(fastCoreName) \((p / 3600).formatted(.number.precision(.fractionLength(2)))) · Efficiency \((max(0, app.cpuSeconds - p) / 3600).formatted(.number.precision(.fractionLength(2)))) core-h"
        case .memory: return "Pico \(bytes(app.peakMemoryBytes))"
        case .disk: return "Leitura \(bytes(app.readBytes)) · gravação \(bytes(app.writtenBytes))"
        case .battery: return "CPU na bateria: \((app.onBatteryCPUSeconds / 3600).formatted(.number.precision(.fractionLength(2)))) core-h"
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

    private func memoryPercent(_ value: Double) -> String {
        let total = Double(model.snapshot?.physicalBytes ?? model.points.last?.physicalBytes ?? 0)
        guard total > 0 else { return "—%" }
        return "\((100 * value / total).formatted(.number.precision(.fractionLength(1))))%"
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
