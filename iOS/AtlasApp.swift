import SwiftUI
import AtlasCore

@main
struct AtlasiOSApp: App {
    @StateObject private var tabs: AtlasTabs
    @StateObject private var health = HealthSyncModel()
    private let sync: HealthKitSync

    init() {
        AtlasPerformance.shared.start()
        let store = AtlasStoreFactory.make()
        let tabs = AtlasTabs(store: store)
        let health = HealthSyncModel()
        let sync = HealthKitSync(
            archiveURL: HealthWalkArchive.url(beside: AtlasDataLocation.defaultDataFile()),
            model: health
        ) {
            // Health wrote new walks: fold them into the loaded snapshot and
            // refetch the list, so the map redraws without a relaunch.
            Task { @MainActor in
                (store as? FileAtlasStore)?.reloadHealthWalks()
                await tabs.walks.refresh()
            }
        }
        _tabs = StateObject(wrappedValue: tabs)
        _health = StateObject(wrappedValue: health)
        self.sync = sync
        tabs.startLoading()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(tabs: tabs, health: health)
                .task { sync.start() }
        }
    }
}
