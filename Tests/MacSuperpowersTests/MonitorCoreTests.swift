import Foundation
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
        let point = MonitorSystemPoint(date: date, cpuPercent: 23,
                                       usedMemoryBytes: 2_000, physicalBytes: 4_000,
                                       diskFreeBytes: 5_000, readBytesPerSecond: 200,
                                       writtenBytesPerSecond: 100, batteryPercent: 75,
                                       onBattery: true, charging: false, thermalState: 1,
                                       coverage: 0.8,
                                       performanceCoreEquivalents: 1.2,
                                       efficiencyCoreEquivalents: 0.4)
        try store.insert(point)
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
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].cpuSeconds, 207)
        XCTAssertEqual(apps[0].averageMemoryBytes, 1_000)
        try store.touchAgent(at: date)
        XCTAssertEqual(try store.lastAgentHeartbeat(), date)
        try store.eraseHistory()
        XCTAssertTrue(try store.loadApps(since: date.addingTimeInterval(-30)).isEmpty)
    }
}
