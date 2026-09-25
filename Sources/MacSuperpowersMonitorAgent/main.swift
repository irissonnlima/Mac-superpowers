import Foundation
import MonitorCore

@main
enum MonitorAgent {
    static func main() {
        let storeURL = ProcessInfo.processInfo.environment["MAC_SUPERPOWERS_MONITOR_DB"].map { URL(fileURLWithPath: $0) }
        guard let store = try? MonitorStore(url: storeURL ?? MonitorStore.defaultURL()) else { return }
        let collector = MonitorCollector(store: store)
        if CommandLine.arguments.contains("--once") {
            if collector.tick() != nil { try? store.touchAgent() }
            return
        }
        while true {
            let didSample = autoreleasepool { collector.tick() != nil }
            if didSample { try? store.touchAgent() }
            let process = ProcessInfo.processInfo
            let interval: TimeInterval
            if process.thermalState == .critical { interval = 90 }
            else if process.thermalState == .serious || process.isLowPowerModeEnabled { interval = 45 }
            else { interval = 20 }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
