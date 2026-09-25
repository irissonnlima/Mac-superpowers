import Foundation

public final class MonitorCollector: @unchecked Sendable {
    private let sampler = MonitorSampler()
    private let store: MonitorStore
    private var previous: MonitorSnapshot?
    private var buckets: [String: MonitorMinuteBucket] = [:]
    private var currentMinute: Int64?
    private var lastPrune = Date.distantPast

    public init(store: MonitorStore) { self.store = store }

    @discardableResult
    public func tick() -> (MonitorSnapshot, MonitorInterval?)? {
        guard let snapshot = sampler.sample() else { return nil }
        let interval = previous.flatMap { MonitorMath.interval(previous: $0, current: snapshot) }
        previous = snapshot
        let minute = Int64(snapshot.date.timeIntervalSince1970 / 60)
        if let oldMinute = currentMinute, oldMinute != minute { flush() }
        currentMinute = minute
        if let interval {
            for app in interval.apps {
                var bucket = buckets[app.id] ?? MonitorMinuteBucket(minute: minute, app: app)
                bucket.add(app, elapsed: interval.elapsed, onBattery: snapshot.onBattery)
                buckets[app.id] = bucket
            }
            // Salva o minuto em andamento para não perder até 60 s se o agente parar.
            try? store.insert(Array(buckets.values))
        }
        let levelNames = snapshot.performanceLevels.map { $0.name.lowercased() }
        let splitLevels = levelNames.count == 2 && levelNames.contains("efficiency")
            && (levelNames.contains("performance") || levelNames.contains("super"))
        let splitApps = interval?.apps.filter { $0.performanceTimeAvailable } ?? []
        let pEquivalents = splitLevels && !splitApps.isEmpty
            ? splitApps.reduce(0) { $0 + $1.performanceCPUSeconds } / max(0.001, interval?.elapsed ?? 0)
            : nil
        let eEquivalents = splitLevels && !splitApps.isEmpty
            ? splitApps.reduce(0) { $0 + max(0, $1.cpuSeconds - $1.performanceCPUSeconds) } / max(0.001, interval?.elapsed ?? 0)
            : nil
        let point = MonitorSystemPoint(
            date: snapshot.date, cpuPercent: interval?.cpuPercent,
            usedMemoryBytes: snapshot.usedMemoryBytes, physicalBytes: snapshot.physicalBytes,
            diskFreeBytes: snapshot.diskFreeBytes,
            readBytesPerSecond: interval.map { $0.apps.reduce(0) { $0 + Double($1.readBytes) } / $0.elapsed } ?? 0,
            writtenBytesPerSecond: interval.map { $0.apps.reduce(0) { $0 + Double($1.writtenBytes) } / $0.elapsed } ?? 0,
            batteryPercent: snapshot.batteryPercent, onBattery: snapshot.onBattery,
            charging: snapshot.charging, thermalState: snapshot.thermalState,
            coverage: interval?.coverage ?? 0,
            performanceCoreEquivalents: pEquivalents,
            efficiencyCoreEquivalents: eEquivalents
        )
        try? store.insert(point)
        if snapshot.date.timeIntervalSince(lastPrune) > 24 * 3600 {
            try? store.prune(now: snapshot.date)
            lastPrune = snapshot.date
        }
        return (snapshot, interval)
    }

    public func flush() {
        try? store.insert(Array(buckets.values))
        buckets.removeAll(keepingCapacity: true)
    }
}
