import Foundation
import SQLite3

public struct MonitorMinuteBucket: Sendable {
    public let minute: Int64
    public let key: String
    public let name: String
    public let isSystem: Bool
    public var cpuSeconds: Double = 0
    public var performanceCPUSeconds: Double = 0
    public var performanceSamples = 0
    public var memoryByteSeconds: Double = 0
    public var observedSeconds: Double = 0
    public var peakMemoryBytes: UInt64 = 0
    public var readBytes: UInt64 = 0
    public var writtenBytes: UInt64 = 0
    public var cpuEnergyJoules: Double = 0
    public var energySamples = 0
    public var onBatteryCPUSeconds: Double = 0
    public var onBatteryCPUEnergyJoules: Double = 0
    public var onBatteryEnergySamples = 0

    public init(minute: Int64, app: MonitorAppActivity) {
        self.minute = minute
        key = app.id
        name = app.name
        isSystem = app.isSystem
    }

    public mutating func add(_ app: MonitorAppActivity, elapsed: TimeInterval, onBattery: Bool = false) {
        cpuSeconds += app.cpuSeconds
        performanceCPUSeconds += app.performanceCPUSeconds
        if app.performanceTimeAvailable { performanceSamples += 1 }
        memoryByteSeconds += Double(app.physicalBytes) * elapsed
        observedSeconds += elapsed
        peakMemoryBytes = max(peakMemoryBytes, app.physicalBytes)
        readBytes &+= app.readBytes
        writtenBytes &+= app.writtenBytes
        cpuEnergyJoules += app.cpuEnergyJoules
        if app.energyAvailable { energySamples += 1 }
        if onBattery {
            onBatteryCPUSeconds += app.cpuSeconds
            onBatteryCPUEnergyJoules += app.cpuEnergyJoules
            if app.energyAvailable { onBatteryEnergySamples += 1 }
        }
    }
}

public final class MonitorStore {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MacSuperpowers/Monitor.sqlite")
    }

    public init(url: URL = MonitorStore.defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw NSError(domain: "MonitorStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Não foi possível abrir o histórico local."])
        }
        _ = chmod(url.path, 0o600)
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("CREATE TABLE IF NOT EXISTS system_sample (ts REAL PRIMARY KEY, cpu REAL, used_memory INTEGER NOT NULL, physical_memory INTEGER NOT NULL, disk_free INTEGER NOT NULL, read_rate REAL NOT NULL, write_rate REAL NOT NULL, battery REAL, on_battery INTEGER NOT NULL, charging INTEGER NOT NULL, thermal INTEGER NOT NULL, coverage REAL NOT NULL, p_core_equivalents REAL, e_core_equivalents REAL)")
        if !hasColumn("p_core_equivalents", in: "system_sample") { try exec("ALTER TABLE system_sample ADD COLUMN p_core_equivalents REAL") }
        if !hasColumn("e_core_equivalents", in: "system_sample") { try exec("ALTER TABLE system_sample ADD COLUMN e_core_equivalents REAL") }
        try exec("CREATE TABLE IF NOT EXISTS app_minute (minute INTEGER NOT NULL, app_key TEXT NOT NULL, name TEXT NOT NULL, is_system INTEGER NOT NULL, cpu_seconds REAL NOT NULL, p_cpu_seconds REAL NOT NULL, p_samples INTEGER NOT NULL, memory_byte_seconds REAL NOT NULL, observed_seconds REAL NOT NULL, peak_memory INTEGER NOT NULL, read_bytes INTEGER NOT NULL, written_bytes INTEGER NOT NULL, cpu_energy REAL NOT NULL, energy_samples INTEGER NOT NULL, battery_cpu_seconds REAL NOT NULL DEFAULT 0, battery_cpu_energy REAL NOT NULL DEFAULT 0, battery_energy_samples INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(minute, app_key))")
        if !hasColumn("battery_cpu_seconds", in: "app_minute") { try exec("ALTER TABLE app_minute ADD COLUMN battery_cpu_seconds REAL NOT NULL DEFAULT 0") }
        if !hasColumn("battery_cpu_energy", in: "app_minute") { try exec("ALTER TABLE app_minute ADD COLUMN battery_cpu_energy REAL NOT NULL DEFAULT 0") }
        if !hasColumn("battery_energy_samples", in: "app_minute") { try exec("ALTER TABLE app_minute ADD COLUMN battery_energy_samples INTEGER NOT NULL DEFAULT 0") }
        try exec("CREATE INDEX IF NOT EXISTS app_minute_by_key ON app_minute(app_key, minute)")
        try exec("CREATE TABLE IF NOT EXISTS agent_heartbeat (id INTEGER PRIMARY KEY CHECK(id = 1), ts REAL NOT NULL)")
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> NSError {
        NSError(domain: "MonitorStore", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    private func hasColumn(_ column: String, in table: String) -> Bool {
        guard let statement = try? prepare("PRAGMA table_info(\(table))") else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(statement, 1)) == column { return true }
        }
        return false
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    public func insert(_ point: MonitorSystemPoint) throws {
        let sql = "INSERT OR REPLACE INTO system_sample VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, point.date.timeIntervalSince1970)
        if let cpu = point.cpuPercent { sqlite3_bind_double(statement, 2, cpu) }
        else { sqlite3_bind_null(statement, 2) }
        sqlite3_bind_int64(statement, 3, Int64(clamping: point.usedMemoryBytes))
        sqlite3_bind_int64(statement, 4, Int64(clamping: point.physicalBytes))
        sqlite3_bind_int64(statement, 5, Int64(clamping: point.diskFreeBytes))
        sqlite3_bind_double(statement, 6, point.readBytesPerSecond)
        sqlite3_bind_double(statement, 7, point.writtenBytesPerSecond)
        if let battery = point.batteryPercent { sqlite3_bind_double(statement, 8, battery) }
        else { sqlite3_bind_null(statement, 8) }
        sqlite3_bind_int(statement, 9, point.onBattery ? 1 : 0)
        sqlite3_bind_int(statement, 10, point.charging ? 1 : 0)
        sqlite3_bind_int(statement, 11, Int32(point.thermalState))
        sqlite3_bind_double(statement, 12, point.coverage)
        if let value = point.performanceCoreEquivalents { sqlite3_bind_double(statement, 13, value) }
        else { sqlite3_bind_null(statement, 13) }
        if let value = point.efficiencyCoreEquivalents { sqlite3_bind_double(statement, 14, value) }
        else { sqlite3_bind_null(statement, 14) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    public func insert(_ buckets: [MonitorMinuteBucket]) throws {
        guard !buckets.isEmpty else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            let sql = "INSERT INTO app_minute VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(minute, app_key) DO UPDATE SET name=excluded.name, is_system=excluded.is_system, cpu_seconds=excluded.cpu_seconds, p_cpu_seconds=excluded.p_cpu_seconds, p_samples=excluded.p_samples, memory_byte_seconds=excluded.memory_byte_seconds, observed_seconds=excluded.observed_seconds, peak_memory=excluded.peak_memory, read_bytes=excluded.read_bytes, written_bytes=excluded.written_bytes, cpu_energy=excluded.cpu_energy, energy_samples=excluded.energy_samples, battery_cpu_seconds=excluded.battery_cpu_seconds, battery_cpu_energy=excluded.battery_cpu_energy, battery_energy_samples=excluded.battery_energy_samples"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            for bucket in buckets {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, bucket.minute)
                bind(bucket.key, to: statement, at: 2)
                bind(bucket.name, to: statement, at: 3)
                sqlite3_bind_int(statement, 4, bucket.isSystem ? 1 : 0)
                sqlite3_bind_double(statement, 5, bucket.cpuSeconds)
                sqlite3_bind_double(statement, 6, bucket.performanceCPUSeconds)
                sqlite3_bind_int(statement, 7, Int32(bucket.performanceSamples))
                sqlite3_bind_double(statement, 8, bucket.memoryByteSeconds)
                sqlite3_bind_double(statement, 9, bucket.observedSeconds)
                sqlite3_bind_int64(statement, 10, Int64(clamping: bucket.peakMemoryBytes))
                sqlite3_bind_int64(statement, 11, Int64(clamping: bucket.readBytes))
                sqlite3_bind_int64(statement, 12, Int64(clamping: bucket.writtenBytes))
                sqlite3_bind_double(statement, 13, bucket.cpuEnergyJoules)
                sqlite3_bind_int(statement, 14, Int32(bucket.energySamples))
                sqlite3_bind_double(statement, 15, bucket.onBatteryCPUSeconds)
                sqlite3_bind_double(statement, 16, bucket.onBatteryCPUEnergyJoules)
                sqlite3_bind_int(statement, 17, Int32(bucket.onBatteryEnergySamples))
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func loadSystem(since: Date, resolution: TimeInterval) throws -> [MonitorSystemPoint] {
        let sql = "SELECT CAST(ts / ? AS INTEGER) * ?, AVG(cpu), AVG(used_memory), MAX(physical_memory), AVG(disk_free), AVG(read_rate), AVG(write_rate), AVG(battery), MAX(on_battery), MAX(charging), MAX(thermal), AVG(coverage), AVG(p_core_equivalents), AVG(e_core_equivalents) FROM system_sample WHERE ts >= ? GROUP BY 1 ORDER BY 1"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, resolution)
        sqlite3_bind_double(statement, 2, resolution)
        sqlite3_bind_double(statement, 3, since.timeIntervalSince1970)
        var points: [MonitorSystemPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            points.append(MonitorSystemPoint(
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                cpuPercent: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 1),
                usedMemoryBytes: UInt64(max(0, sqlite3_column_int64(statement, 2))),
                physicalBytes: UInt64(max(0, sqlite3_column_int64(statement, 3))),
                diskFreeBytes: UInt64(max(0, sqlite3_column_int64(statement, 4))),
                readBytesPerSecond: sqlite3_column_double(statement, 5),
                writtenBytesPerSecond: sqlite3_column_double(statement, 6),
                batteryPercent: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 7),
                onBattery: sqlite3_column_int(statement, 8) != 0,
                charging: sqlite3_column_int(statement, 9) != 0,
                thermalState: Int(sqlite3_column_int(statement, 10)),
                coverage: sqlite3_column_double(statement, 11),
                performanceCoreEquivalents: sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 12),
                efficiencyCoreEquivalents: sqlite3_column_type(statement, 13) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 13)
            ))
        }
        return points
    }

    public func loadApps(since: Date) throws -> [MonitorAppTotal] {
        let sql = "SELECT app_key, MAX(name), MAX(is_system), SUM(cpu_seconds), SUM(p_cpu_seconds), SUM(p_samples), SUM(memory_byte_seconds) / MAX(1, SUM(observed_seconds)), MAX(peak_memory), SUM(read_bytes), SUM(written_bytes), SUM(cpu_energy), SUM(energy_samples), SUM(battery_cpu_seconds), SUM(battery_cpu_energy), SUM(battery_energy_samples) FROM app_minute WHERE minute >= ? GROUP BY app_key"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 / 60))
        var result: [MonitorAppTotal] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(MonitorAppTotal(
                id: String(cString: sqlite3_column_text(statement, 0)),
                name: String(cString: sqlite3_column_text(statement, 1)),
                isSystem: sqlite3_column_int(statement, 2) != 0,
                cpuSeconds: sqlite3_column_double(statement, 3),
                performanceCPUSeconds: sqlite3_column_int(statement, 5) > 0 ? sqlite3_column_double(statement, 4) : nil,
                averageMemoryBytes: sqlite3_column_double(statement, 6),
                peakMemoryBytes: UInt64(max(0, sqlite3_column_int64(statement, 7))),
                readBytes: UInt64(max(0, sqlite3_column_int64(statement, 8))),
                writtenBytes: UInt64(max(0, sqlite3_column_int64(statement, 9))),
                cpuEnergyJoules: sqlite3_column_int(statement, 11) > 0 ? sqlite3_column_double(statement, 10) : nil,
                onBatteryCPUSeconds: sqlite3_column_double(statement, 12),
                onBatteryCPUEnergyJoules: sqlite3_column_int(statement, 14) > 0 ? sqlite3_column_double(statement, 13) : nil
            ))
        }
        return result
    }

    public func touchAgent(at date: Date = Date()) throws {
        let statement = try prepare("INSERT INTO agent_heartbeat(id, ts) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET ts = excluded.ts")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    public func lastAgentHeartbeat() throws -> Date? {
        let statement = try prepare("SELECT ts FROM agent_heartbeat WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    public func prune(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970
        try exec("DELETE FROM system_sample WHERE ts < \(cutoff)")
        try exec("DELETE FROM app_minute WHERE minute < \(Int64(cutoff / 60))")
        try exec("PRAGMA wal_checkpoint(PASSIVE)")
    }

    public func eraseHistory() throws {
        try exec("DELETE FROM system_sample")
        try exec("DELETE FROM app_minute")
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }
}
