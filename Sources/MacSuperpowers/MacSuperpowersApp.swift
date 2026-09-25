import SwiftUI

@main
struct MacSuperpowersApp: App {
    var body: some Scene {
        WindowGroup("Mac Superpowers") {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
