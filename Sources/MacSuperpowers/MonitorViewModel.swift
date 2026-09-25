import Foundation
import MonitorCore
import ServiceManagement

enum MonitorCategory: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memória"
    case disk = "Disco"
    case battery = "Bateria"
    case thermal = "Térmico"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "externaldrive"
        case .battery: "battery.75percent"
        case .thermal: "thermometer.medium"
        }
    }
}

enum MonitorRange: String, CaseIterable, Identifiable {
    case fifteenMinutes = "15 min"
    case oneHour = "1 h"
    case oneDay = "24 h"
    case sevenDays = "7 dias"
    case thirtyDays = "30 dias"

    var id: Self { self }
    var duration: TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour: 3600
        case .oneDay: 24 * 3600
        case .sevenDays: 7 * 24 * 3600
        case .thirtyDays: 30 * 24 * 3600
        }
    }
    var resolution: TimeInterval {
        switch self {
        case .fifteenMinutes: 15
        case .oneHour: 30
        case .oneDay: 5 * 60
        case .sevenDays: 30 * 60
        case .thirtyDays: 2 * 3600
        }
    }
}

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published var category: MonitorCategory = .cpu
    @Published var range: MonitorRange = .oneHour {
        didSet { refreshHistory() }
    }
    @Published private(set) var snapshot: MonitorSnapshot?
    @Published private(set) var interval: MonitorInterval?
    @Published private(set) var points: [MonitorSystemPoint] = []
    @Published private(set) var totals: [MonitorAppTotal] = []
    @Published private(set) var temperaturePoints: [MonitorTemperaturePoint] = []
    @Published private(set) var temperatureStatistics: [MonitorTemperatureStatistics] = []
    @Published private(set) var externalPowerPoints: [MonitorExternalPowerPoint] = []
    @Published var selectedTemperatureSensorID: String? {
        didSet { refreshTemperatureHistory() }
    }
    @Published private(set) var backgroundActive = false
    @Published private(set) var backgroundPending = false
    @Published private(set) var backgroundHealthy = false
    @Published var notice: String?

    private let sampler = MonitorSampler()
    private var previous: MonitorSnapshot?
    private var store: MonitorStore?
    private var fallbackCollector: MonitorCollector?
    private var timer: Timer?
    private var visible = false
    private var started = false
    private var samplingInFlight = false
    private var lastHistoryRefresh = Date.distantPast
    private var lastLiveTemperatureStored: Date?
    private let agentPlist = "com.macsuperpowers.monitor.plist"

    var hasBattery: Bool { snapshot?.batteryPercent != nil || points.contains { $0.batteryPercent != nil } }
    var liveApps: [MonitorAppActivity] { interval?.apps ?? [] }
    var dataStatus: String {
        if backgroundActive && backgroundHealthy { "Histórico em segundo plano ativo" }
        else if backgroundActive { "Agente sem amostra recente; coleta com o app aberto" }
        else if backgroundPending { "Aguardando autorização nos Ajustes do Sistema" }
        else { "Histórico somente enquanto o app estiver aberto" }
    }

    func start() {
        guard !started else { return }
        started = true
        do { store = try MonitorStore() }
        catch { notice = "Não foi possível abrir o histórico local: \(error.localizedDescription)" }
        refreshAgentRegistration()
        configureFallback()
        refreshHistory()
        schedule()
    }

    func setVisible(_ value: Bool) {
        visible = value
        if value { sampleLive(); refreshHistory() }
        schedule()
    }

    func setBackgroundEnabled(_ enabled: Bool) {
        let service = SMAppService.agent(plistName: agentPlist)
        do {
            if enabled, service.status != .enabled && service.status != .requiresApproval {
                try service.register()
            }
            if !enabled, service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
            UserDefaults.standard.set(!enabled, forKey: "MonitorBackgroundDisabled")
        } catch {
            notice = "O macOS não ativou a coleta em segundo plano: \(error.localizedDescription)"
        }
        updateAgentState()
        if enabled && backgroundPending {
            notice = "Autorize Mac Superpowers em Ajustes do Sistema › Geral › Itens de Início para manter o histórico com o app fechado."
        }
        configureFallback()
        schedule()
    }

    func eraseHistory() {
        do {
            try store?.eraseHistory()
            points = []
            totals = []
            temperaturePoints = []
            temperatureStatistics = []
            externalPowerPoints = []
        } catch { notice = "Não foi possível apagar o histórico: \(error.localizedDescription)" }
    }

    private func refreshAgentRegistration() {
        let service = SMAppService.agent(plistName: agentPlist)
        let packagedPlist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(agentPlist)")
        if FileManager.default.fileExists(atPath: packagedPlist.path),
           !UserDefaults.standard.bool(forKey: "MonitorBackgroundDisabled"),
           service.status != .enabled && service.status != .requiresApproval {
            do { try service.register() }
            catch { notice = "Não foi possível iniciar o agente em segundo plano: \(error.localizedDescription)" }
        }
        updateAgentState()
    }

    private func configureFallback() {
        if backgroundHealthy { fallbackCollector = nil }
        else if fallbackCollector == nil, let store { fallbackCollector = MonitorCollector(store: store) }
    }

    private func updateAgentState() {
        let status = SMAppService.agent(plistName: agentPlist).status
        backgroundActive = status == .enabled
        backgroundPending = status == .requiresApproval
        let heartbeat = try? store?.lastAgentHeartbeat()
        backgroundHealthy = backgroundActive && heartbeat.map { Date().timeIntervalSince($0) < 130 } == true
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard started else { return }
        timer = Timer(timeInterval: visible ? 10 : 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLive() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func sampleLive() {
        guard !samplingInFlight else { return }
        let wasActive = backgroundActive
        let wasHealthy = backgroundHealthy
        updateAgentState()
        if wasActive != backgroundActive || wasHealthy != backgroundHealthy {
            configureFallback()
            schedule()
        }
        if !visible && backgroundHealthy { return }
        samplingInFlight = true
        let collector = fallbackCollector
        let sampler = sampler
        let oldSnapshot = previous
        Task.detached(priority: .utility) { [weak self] in
            let result: (MonitorSnapshot, MonitorInterval?)?
            if let collector { result = collector.tick() }
            else if let sample = sampler.sample() {
                result = (sample, oldSnapshot.flatMap { MonitorMath.interval(previous: $0, current: sample) })
            } else { result = nil }
            await MainActor.run {
                guard let self else { return }
                self.samplingInFlight = false
                if let (sample, delta) = result {
                    self.previous = sample
                    self.snapshot = sample
                    self.interval = delta
                    if let watts = sample.batteryPowerWatts {
                        try? self.store?.insertBatteryPower(watts, at: sample.date)
                    }
                    try? self.store?.insertExternalPower(inputWatts: sample.inputPowerWatts,
                                                         systemLoadWatts: sample.systemLoadWatts, at: sample.date)
                    if let sampledAt = sample.temperatureSampleDate,
                       sampledAt != self.lastLiveTemperatureStored,
                       !sample.temperatures.isEmpty {
                        try? self.store?.insertTemperatures(sample.temperatures, date: sampledAt)
                        self.lastLiveTemperatureStored = sampledAt
                    }
                    if self.selectedTemperatureSensorID == nil {
                        self.selectedTemperatureSensorID = sample.temperatures.first(where: { $0.id == "SMC:TCMz" })?.id
                            ?? sample.temperatures.first(where: { $0.id == "SMC:TCMb" })?.id
                            ?? sample.temperatures.first?.id
                    }
                }
                if self.visible, Date().timeIntervalSince(self.lastHistoryRefresh) > 15 { self.refreshHistory() }
            }
        }
    }

    func refreshHistory() {
        guard let store else { return }
        let since = Date().addingTimeInterval(-range.duration)
        do {
            points = try store.loadSystem(since: since, resolution: range.resolution)
            totals = try store.loadApps(since: since)
            externalPowerPoints = try store.loadExternalPower(since: since, resolution: range.resolution)
            temperatureStatistics = try store.loadTemperatureStatistics(since: since)
            refreshTemperatureHistory()
            lastHistoryRefresh = Date()
        } catch { notice = "Não foi possível ler o histórico: \(error.localizedDescription)" }
    }

    private func refreshTemperatureHistory() {
        guard let store, let selectedTemperatureSensorID else {
            temperaturePoints = []
            return
        }
        temperaturePoints = (try? store.loadTemperatures(sensorID: selectedTemperatureSensorID,
                                                         since: Date().addingTimeInterval(-range.duration))) ?? []
    }
}
