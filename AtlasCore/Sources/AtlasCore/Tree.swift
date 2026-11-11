import Foundation
import Combine

public final class IntrospectionTree {
    public let root: IntrospectionNode
    public init(root: IntrospectionNode) { self.root = root }
    public var focused: IntrospectionNode {
        var node = root
        while let child = node.child?() { node = child }
        return node
    }
}

@MainActor
public final class AtlasTabs: ObservableObject {
    public let walks: WalksViewModel
    public let places: PlacesViewModel
    public let flights: FlightsViewModel
    public let parcels: ParcelsViewModel
    public let tfl: TFLViewModel
    public let cameras: CamerasViewModel
    public let map: MapViewModel
    @Published public var selected: Int = 0
    private let store: any AtlasDataSource
    private var subscriptions: Set<AnyCancellable> = []

    public init(
        store: any AtlasDataSource,
        pageSize: Int = 100,
        jamCams: any JamCamProviding = TFLJamCamClient()
    ) {
        self.store = store
        self.walks = WalksViewModel(store: store, pageSize: pageSize)
        self.places = PlacesViewModel(store: store)
        self.flights = FlightsViewModel(store: store)
        self.parcels = ParcelsViewModel(store: store)
        self.tfl = TFLViewModel(store: store)
        self.cameras = CamerasViewModel(provider: jamCams)
        self.map = MapViewModel()

        // `AtlasTabs` is the single object a view observes. Forward every child
        // change so async loads actually redraw the app.
        for child in [walks.objectWillChange, places.objectWillChange, flights.objectWillChange,
                      parcels.objectWillChange, tfl.objectWillChange, cameras.objectWillChange] {
            child
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &subscriptions)
        }
    }

    private var loadTask: Task<Void, Never>?

    /// Begin loading before the first frame. The app calls this in `init`, so
    /// decode overlaps MapKit's scene setup instead of running after it.
    public func startLoading() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
    }

    /// Load every feature. Safe to call more than once; the first call owns the
    /// work and later callers await the same task.
    public func load() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        AtlasPerformance.shared.begin("tabs.load")
        await store.waitUntilReady()
        AtlasPerformance.shared.mark("store.ready")
        await walks.refresh(force: true)
        AtlasPerformance.shared.mark("walks.summaries")
        await walks.loadAll()
        await places.refresh()
        await flights.refresh()
        await parcels.refresh()
        await tfl.refresh()
        AtlasPerformance.shared.end("tabs.load")
        AtlasPerformance.shared.increment("loads.tabs")
    }

    public var activeNode: IntrospectionNode {
        let base: IntrospectionNode
        switch selected {
        case 0: base = walks.introspectionNode
        case 1: base = places.introspectionNode
        case 2: base = flights.introspectionNode
        case 3: base = parcels.introspectionNode
        case 4: base = tfl.introspectionNode
        default: base = cameras.introspectionNode
        }
        // Map actions and camera state are always reachable from the active tab,
        // so an agent can drive the base layer from any feature.
        return base.appending(actions: map.introspectionNode.actions, contextJSON: map.mapStateJSON)
    }
}

@MainActor
public func makeAtlasTree(tabs: AtlasTabs) -> IntrospectionTree {
    let activeProvider: () -> IntrospectionNode? = { tabs.activeNode }
    let navNode = IntrospectionNode(name: "Navigator", stateJSON: "{}", actions: [], child: activeProvider)
    let root = IntrospectionNode(name: "App", stateJSON: "{}", actions: [], child: { navNode })
    return IntrospectionTree(root: root)
}

@MainActor
public func makeAtlasTree(store: any AtlasDataSource) -> (tree: IntrospectionTree, tabs: AtlasTabs) {
    let tabs = AtlasTabs(store: store)
    return (makeAtlasTree(tabs: tabs), tabs)
}
