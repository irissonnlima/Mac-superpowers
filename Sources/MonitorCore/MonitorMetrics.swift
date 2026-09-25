import Foundation

public struct MonitorPerformanceLevel: Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let logicalCores: Int
}

public struct MonitorProcess: Sendable {
    public let pid: Int32
    public let startTime: UInt64
    public let key: String
    public let name: String
    public let isSystem: Bool
    public let cpuSeconds: Double
    public let performanceCPUSeconds: Double?
    public let physicalBytes: UInt64
    public let readBytes: UInt64
    public let writtenBytes: UInt64
    public let cpuEnergyJoules: Double?

    public var identity: String { "\(pid):\(startTime)" }
}

public struct MonitorSnapshot: Sendable {
    public let date: Date
    public let uptime: TimeInterval
    public let busyTicks: UInt64
    public let totalTicks: UInt64
    public let physicalBytes: UInt64
    public let usedMemoryBytes: UInt64
    public let diskTotalBytes: UInt64
    public let diskFreeBytes: UInt64
    public let batteryPercent: Double?
    public let onBattery: Bool
    public let charging: Bool
    public let lowPowerMode: Bool
    public let thermalState: Int
    public let processes: [MonitorProcess]
    public let performanceLevels: [MonitorPerformanceLevel]
    public let inaccessibleProcessCount: Int
}

public struct MonitorAppActivity: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isSystem: Bool
    public var cpuSeconds: Double = 0
    public var performanceCPUSeconds: Double = 0
    public var performanceTimeAvailable = false
    public var physicalBytes: UInt64 = 0
    public var readBytes: UInt64 = 0
    public var writtenBytes: UInt64 = 0
    public var cpuEnergyJoules: Double = 0
    public var energyAvailable = false
    public var observedProcessCount = 0

    public init(id: String, name: String, isSystem: Bool) {
        self.id = id
        self.name = name
        self.isSystem = isSystem
    }
}

public struct MonitorInterval: Sendable {
    public let elapsed: TimeInterval
    public let cpuPercent: Double?
    public let apps: [MonitorAppActivity]
    public let coverage: Double
}

public enum MonitorMath {
    public static func interval(previous: MonitorSnapshot, current: MonitorSnapshot) -> MonitorInterval? {
        let elapsed = current.uptime - previous.uptime
        guard elapsed > 0, elapsed < 120, current.totalTicks >= previous.totalTicks,
              current.busyTicks >= previous.busyTicks else { return nil }

        let totalDelta = current.totalTicks - previous.totalTicks
        let busyDelta = current.busyTicks - previous.busyTicks
        let cpuPercent = totalDelta > 0 ? min(100, 100 * Double(busyDelta) / Double(totalDelta)) : nil
        let oldProcesses = Dictionary(uniqueKeysWithValues: previous.processes.map { ($0.identity, $0) })
        var grouped: [String: MonitorAppActivity] = [:]

        for process in current.processes {
            var app = grouped[process.key] ?? MonitorAppActivity(id: process.key, name: process.name, isSystem: process.isSystem)
            app.physicalBytes &+= process.physicalBytes
            app.observedProcessCount += 1
            if let old = oldProcesses[process.identity] {
                if process.cpuSeconds >= old.cpuSeconds {
                    app.cpuSeconds += process.cpuSeconds - old.cpuSeconds
                }
                if let newP = process.performanceCPUSeconds, let oldP = old.performanceCPUSeconds, newP >= oldP {
                    app.performanceCPUSeconds += newP - oldP
                    app.performanceTimeAvailable = true
                }
                if process.readBytes >= old.readBytes { app.readBytes &+= process.readBytes - old.readBytes }
                if process.writtenBytes >= old.writtenBytes { app.writtenBytes &+= process.writtenBytes - old.writtenBytes }
                if let newEnergy = process.cpuEnergyJoules, let oldEnergy = old.cpuEnergyJoules,
                   newEnergy >= oldEnergy {
                    app.cpuEnergyJoules += newEnergy - oldEnergy
                    app.energyAvailable = true
                }
            }
            grouped[process.key] = app
        }
        let readable = current.processes.count
        let coverage = Double(readable) / Double(max(1, readable + current.inaccessibleProcessCount))
        return MonitorInterval(elapsed: elapsed, cpuPercent: cpuPercent,
                               apps: Array(grouped.values), coverage: coverage)
    }
}

public struct MonitorSystemPoint: Sendable, Identifiable {
    public let date: Date
    public let cpuPercent: Double?
    public let usedMemoryBytes: UInt64
    public let physicalBytes: UInt64
    public let diskFreeBytes: UInt64
    public let readBytesPerSecond: Double
    public let writtenBytesPerSecond: Double
    public let batteryPercent: Double?
    public let onBattery: Bool
    public let charging: Bool
    public let thermalState: Int
    public let coverage: Double
    public let performanceCoreEquivalents: Double?
    public let efficiencyCoreEquivalents: Double?
    public var id: Date { date }
}

public struct MonitorAppTotal: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isSystem: Bool
    public let cpuSeconds: Double
    public let performanceCPUSeconds: Double?
    public let averageMemoryBytes: Double
    public let peakMemoryBytes: UInt64
    public let readBytes: UInt64
    public let writtenBytes: UInt64
    public let cpuEnergyJoules: Double?
    public let onBatteryCPUSeconds: Double
    public let onBatteryCPUEnergyJoules: Double?
}
