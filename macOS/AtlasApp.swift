import SwiftUI
import AppKit
import AtlasCore

@main
struct AtlasMacApp: App {
    @StateObject private var tabs: AtlasTabs

    init() {
        AtlasPerformance.shared.start()
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        _tabs = StateObject(wrappedValue: AtlasTabs(store: AtlasStoreFactory.make()))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(tabs: tabs)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
    }
}
