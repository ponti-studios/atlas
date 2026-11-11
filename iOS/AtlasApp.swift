import SwiftUI
import AtlasCore

@main
struct AtlasiOSApp: App {
    @StateObject private var tabs: AtlasTabs

    init() {
        AtlasPerformance.shared.start()
        let tabs = AtlasTabs(store: AtlasStoreFactory.make())
        _tabs = StateObject(wrappedValue: tabs)
        tabs.startLoading()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(tabs: tabs)
        }
    }
}