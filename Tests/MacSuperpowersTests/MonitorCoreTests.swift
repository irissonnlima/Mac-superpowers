import Foundation
import SQLite3
import XCTest
@testable import MonitorCore

final class MonitorCoreTests: XCTestCase {
    private func process(pid: Int32 = 42, start: UInt64 = 1, cpu: Double,
                         pCPU: Double? = 0, memory: UInt64 = 1_000,
                         read: UInt64 = 0) -> MonitorProcess {
        MonitorProcess(pid: pid, startTime: start, key: "com.example.Test", name: "Teste",
                       isSystem: false, cpuSeconds: cpu, performanceCPUSeconds: pCPU,
                       physicalBytes: memory, readBytes: read, writtenBytes: 0,
                       cpuEnergyJoules: nil)
    }

    private func snapshot(at time: TimeInterval, process: MonitorProcess,
                          busy: UInt64 = 100, total: UInt64 = 200) -> MonitorSnapshot {
        MonitorSnapshot(date: Date(timeIntervalSince1970: time), uptime: time,
                        busyTicks: busy, totalTicks: total,
                        physicalBytes: 16_000, usedMemoryBytes: 8_000,
                        diskTotalBytes: 100_000, diskFreeBytes: 50_000,
                        batteryPercent: 50, onBattery: true, charging: false,
                        lowPowerMode: false, thermalState: 0,
                        processes: [process], performanceLevels: [],
                        inaccessibleProcessCount: 0)
    }

    func testCoreSecondsAndReusedPID() throws {
        let before = snapshot(at: 100, process: process(cpu: 10, pCPU: 4, read: 10),
                              busy: 100, total: 200)
        let after = snapshot(at: 190, process: process(cpu: 217, pCPU: 104, read: 1_010),
                             busy: 150, total: 300)
        let delta = try XCTUnwrap(MonitorMath.interval(previous: before, current: after))
        XCTAssertEqual(delta.elapsed, 90)
        XCTAssertEqual(delta.cpuPercent, 50)
        XCTAssertEqual(delta.apps[0].cpuSeconds, 207, accuracy: 0.0001)
        XCTAssertEqual(delta.apps[0].cpuSeconds / delta.elapsed, 2.3, accuracy: 0.0001)
        XCTAssertEqual(delta.apps[0].performanceCPUSeconds, 100, accuracy: 0.0001)
        XCTAssertEqual(delta.apps[0].readBytes, 1_000)

        let reused = snapshot(at: 200, process: process(start: 2, cpu: 9), busy: 160, total: 320)
        let reusedDelta = try XCTUnwrap(MonitorMath.interval(previous: after, current: reused))
        XCTAssertEqual(reusedDelta.apps[0].cpuSeconds, 0)
        XCTAssertEqual(reusedDelta.apps[0].physicalBytes, 1_000)
    }

    func testSleepGapIsNotCountedAsZero() {
        let before = snapshot(at: 100, process: process(cpu: 10))
        let after = snapshot(at: 400, process: process(cpu: 20))
        XCTAssertNil(MonitorMath.interval(previous: before, current: after))
    }

    func testSQLiteRoundTripAndErase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MonitorStore(url: directory.appendingPathComponent("Monitor.sqlite"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var point = MonitorSystemPoint(date: date, cpuPercent: 23,
                                       usedMemoryBytes: 2_000, physicalBytes: 4_000,
                                       diskFreeBytes: 5_000, readBytesPerSecond: 200,
                                       writtenBytesPerSecond: 100, batteryPercent: 75,
                                       onBattery: true, charging: false, thermalState: 1,
                                       coverage: 0.8,
                                       performanceCoreEquivalents: 1.2,
                                       efficiencyCoreEquivalents: 0.4)
        point.batteryPowerWatts = -12.5
        try store.insert(point)
        try store.insertExternalPower(inputWatts: 18.4, systemLoadWatts: 12.2, at: date.addingTimeInterval(1))
        try store.insertTemperatures([
            MonitorTemperature(id: "SMC:TCMz", celsius: 63.4, source: 1),
            MonitorTemperature(id: "Battery:Pack", celsius: 32.1, source: 3)
        ], date: date)
        var activity = MonitorAppActivity(id: "com.example.Test", name: "Teste", isSystem: false)
        activity.cpuSeconds = 207
        activity.performanceCPUSeconds = 100
        activity.performanceTimeAvailable = true
        activity.physicalBytes = 1_000
        activity.readBytes = 500
        var bucket = MonitorMinuteBucket(minute: Int64(date.timeIntervalSince1970 / 60), app: activity)
        bucket.add(activity, elapsed: 90)
        try store.insert([bucket])
        let points = try store.loadSystem(since: date.addingTimeInterval(-30), resolution: 15)
        let apps = try store.loadApps(since: date.addingTimeInterval(-30))
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].cpuPercent, 23)
        XCTAssertEqual(points[0].performanceCoreEquivalents, 1.2)
        XCTAssertEqual(points[0].batteryPowerWatts, -12.5)
        let externalPower = try store.loadExternalPower(since: date.addingTimeInterval(-30), resolution: 15)
        XCTAssertEqual(externalPower.count, 1)
        XCTAssertEqual(externalPower[0].inputWatts ?? 0, 18.4, accuracy: 0.001)
        XCTAssertEqual(externalPower[0].systemLoadWatts ?? 0, 12.2, accuracy: 0.001)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].cpuSeconds, 207)
        XCTAssertEqual(apps[0].averageMemoryBytes, 1_000)
        let temperatures = try store.loadTemperatures(sensorID: "SMC:TCMz", since: date.addingTimeInterval(-300))
        XCTAssertEqual(temperatures.count, 1)
        XCTAssertEqual(temperatures[0].celsius, 63.4, accuracy: 0.001)
        try store.touchAgent(at: date)
        XCTAssertEqual(try store.lastAgentHeartbeat(), date)
        try store.eraseHistory()
        XCTAssertTrue(try store.loadApps(since: date.addingTimeInterval(-30)).isEmpty)
        XCTAssertTrue(try store.loadTemperatures(sensorID: "SMC:TCMz", since: date.addingTimeInterval(-300)).isEmpty)
        XCTAssertTrue(try store.loadExternalPower(since: date.addingTimeInterval(-30), resolution: 15).isEmpty)
    }

    func testOldAgentCanStillWriteWhilePowerHistoryIsEnabled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Monitor.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let legacySchema = "CREATE TABLE system_sample (ts REAL PRIMARY KEY, cpu REAL, used_memory INTEGER NOT NULL, physical_memory INTEGER NOT NULL, disk_free INTEGER NOT NULL, read_rate REAL NOT NULL, write_rate REAL NOT NULL, battery REAL, on_battery INTEGER NOT NULL, charging INTEGER NOT NULL, thermal INTEGER NOT NULL, coverage REAL NOT NULL, p_core_equivalents REAL, e_core_equivalents REAL)"
        XCTAssertEqual(sqlite3_exec(database, legacySchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = try MonitorStore(url: url)
        var point = MonitorSystemPoint(date: Date(timeIntervalSince1970: 1_700_000_000), cpuPercent: 20,
                                       usedMemoryBytes: 100, physicalBytes: 200, diskFreeBytes: 300,
                                       readBytesPerSecond: 0, writtenBytesPerSecond: 0,
                                       batteryPercent: 50, onBattery: false, charging: true,
                                       thermalState: 0, coverage: 1,
                                       performanceCoreEquivalents: nil, efficiencyCoreEquivalents: nil)
        point.batteryPowerWatts = 18.2
        try store.insert(point)
        let loaded = try XCTUnwrap(store.loadSystem(since: point.date.addingTimeInterval(-10), resolution: 10).first)
        XCTAssertEqual(loaded.batteryPowerWatts ?? 0, 18.2, accuracy: 0.001)

        var oldAgentDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &oldAgentDatabase), SQLITE_OK)
        let oldInsert = "INSERT INTO system_sample VALUES (1700000020, 21, 100, 200, 300, 0, 0, 50, 0, 1, 0, 1, NULL, NULL)"
        XCTAssertEqual(sqlite3_exec(oldAgentDatabase, oldInsert, nil, nil, nil), SQLITE_OK)
        sqlite3_close(oldAgentDatabase)
        try store.insertBatteryPower(7.5, at: Date(timeIntervalSince1970: 1_700_000_021))
        let mixedPoints = try store.loadSystem(since: point.date.addingTimeInterval(-10), resolution: 10)
        XCTAssertEqual(mixedPoints.count, 2)
        XCTAssertEqual(mixedPoints[1].batteryPowerWatts ?? 0, 7.5, accuracy: 0.001)
    }

    func testIntermediatePowerColumnMovesToCompatibleTable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Monitor.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let intermediateSchema = "CREATE TABLE system_sample (ts REAL PRIMARY KEY, cpu REAL, used_memory INTEGER NOT NULL, physical_memory INTEGER NOT NULL, disk_free INTEGER NOT NULL, read_rate REAL NOT NULL, write_rate REAL NOT NULL, battery REAL, on_battery INTEGER NOT NULL, charging INTEGER NOT NULL, thermal INTEGER NOT NULL, coverage REAL NOT NULL, p_core_equivalents REAL, e_core_equivalents REAL, battery_power_watts REAL)"
        XCTAssertEqual(sqlite3_exec(database, intermediateSchema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO system_sample VALUES (1700000000, 20, 100, 200, 300, 0, 0, 50, 0, 1, 0, 1, NULL, NULL, 18.2)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let store = try MonitorStore(url: url)
        let loaded = try XCTUnwrap(store.loadSystem(since: Date(timeIntervalSince1970: 1_699_999_990), resolution: 10).first)
        XCTAssertEqual(loaded.batteryPowerWatts ?? 0, 18.2, accuracy: 0.001)
        var oldAgentDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &oldAgentDatabase), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(oldAgentDatabase, "INSERT INTO system_sample VALUES (1700000020, 21, 100, 200, 300, 0, 0, 50, 0, 1, 0, 1, NULL, NULL)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(oldAgentDatabase)
    }
}
