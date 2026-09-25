import AppKit
import CSystemMonitor
import Foundation

public final class MonitorSampler: @unchecked Sendable {
    private var appCache: [String: (key: String, name: String)] = [:]
    private var lastTemperatureSample = Date.distantPast
    private var lastTemperatures: [MonitorTemperature] = []
    public let performanceLevels: [MonitorPerformanceLevel]

    public init() {
        var levels: [MonitorPerformanceLevel] = []
        for index in 0..<Int(ms_performance_level_count()) {
            var name = [CChar](repeating: 0, count: 128)
            let cores = ms_performance_level(Int32(index), &name, Int32(name.count))
            if cores > 0 {
                let prefix = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                levels.append(.init(id: index, name: String(decoding: prefix, as: UTF8.self), logicalCores: Int(cores)))
            }
        }
        performanceLevels = levels
    }

    public func sample() -> MonitorSnapshot? {
        var system = MSSystemSample()
        guard ms_read_system(&system) != 0 else { return nil }
        var battery = MSBatterySample()
        let hasBattery = ms_read_battery(&battery) != 0
        let disk = (try? FileManager.default.attributesOfFileSystem(forPath: "/")) ?? [:]
        let total = (disk[.systemSize] as? NSNumber)?.uint64Value ?? 0
        let free = (disk[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        var pids = [Int32](repeating: 0, count: 4096)
        let count = min(pids.count, Int(ms_list_pids(&pids, Int32(pids.count))))
        var processes: [MonitorProcess] = []
        processes.reserveCapacity(count)
        var inaccessible = 0
        for pid in pids.prefix(count) where pid > 0 {
            var raw = MSProcessSample()
            guard ms_read_process(pid, &raw) != 0 else { inaccessible += 1; continue }
            let path = withUnsafePointer(to: &raw.path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
            }
            let app = identity(for: path, pid: pid)
            processes.append(MonitorProcess(
                pid: pid, startTime: raw.start_time, key: app.key, name: app.name,
                isSystem: path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/"),
                cpuSeconds: raw.cpu_seconds,
                performanceCPUSeconds: raw.has_performance_time != 0 ? raw.performance_cpu_seconds : nil,
                physicalBytes: raw.physical_bytes, readBytes: raw.read_bytes,
                writtenBytes: raw.written_bytes,
                cpuEnergyJoules: raw.has_energy != 0 ? raw.cpu_energy_joules : nil
            ))
        }
        let now = Date()
        if now.timeIntervalSince(lastTemperatureSample) >= 60 {
            var sensors = [MSTemperatureSample](repeating: MSTemperatureSample(), count: 256)
            let read = max(0, min(sensors.count, Int(ms_read_temperatures(&sensors, Int32(sensors.count)))))
            var unique: [String: MonitorTemperature] = [:]
            for sensor in sensors.prefix(read) {
                let id = withUnsafePointer(to: sensor.identifier) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
                }
                guard !id.isEmpty, sensor.celsius.isFinite else { continue }
                unique[id] = MonitorTemperature(id: id, celsius: sensor.celsius, source: Int(sensor.source))
            }
            lastTemperatures = unique.values.sorted { $0.id < $1.id }
            lastTemperatureSample = now
        }
        var snapshot = MonitorSnapshot(
            date: now, uptime: ProcessInfo.processInfo.systemUptime,
            busyTicks: system.busy_ticks, totalTicks: system.total_ticks,
            physicalBytes: system.physical_bytes, usedMemoryBytes: system.used_bytes,
            diskTotalBytes: total, diskFreeBytes: free,
            batteryPercent: hasBattery ? battery.percent : nil,
            onBattery: hasBattery && battery.on_battery != 0,
            charging: hasBattery && battery.charging != 0,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            processes: processes, performanceLevels: performanceLevels,
            inaccessibleProcessCount: inaccessible
        )
        snapshot.batteryPowerWatts = hasBattery && battery.power_available != 0 ? battery.power_watts : nil
        snapshot.adapterRatedWatts = hasBattery && battery.adapter_watts > 0 ? Int(battery.adapter_watts) : nil
        snapshot.inputPowerWatts = hasBattery && battery.on_battery == 0 && battery.input_power_available != 0
            ? battery.input_power_watts : nil
        snapshot.systemLoadWatts = hasBattery && battery.system_load_available != 0 ? battery.system_load_watts : nil
        snapshot.temperatures = lastTemperatures
        snapshot.temperatureSampleDate = lastTemperatureSample == .distantPast ? nil : lastTemperatureSample
        return snapshot
    }

    private func identity(for path: String, pid: Int32) -> (key: String, name: String) {
        if path.isEmpty { return ("process:pid:\(pid)", "Processo \(pid)") }
        if let cached = appCache[path] { return cached }
        if appCache.count >= 4096 { appCache.removeAll(keepingCapacity: true) }
        let parts = URL(fileURLWithPath: path).pathComponents
        if let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundlePath = NSString.path(withComponents: Array(parts.prefix(index + 1)))
            if let bundle = Bundle(path: bundlePath) {
                let key = bundle.bundleIdentifier ?? bundlePath
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? String(parts[index].dropLast(4))
                let value = (key, name)
                appCache[path] = value
                return value
            }
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        // Executáveis sem bundle podem compartilhar um nome; o caminho evita somar apps distintos.
        let value = ("process:\(path)", name)
        appCache[path] = value
        return value
    }
}
