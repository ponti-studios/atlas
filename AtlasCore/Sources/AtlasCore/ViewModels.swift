import Foundation
import CoreLocation

// MARK: - Walks ViewModel (ported)

@MainActor
public final class WalksViewModel: ObservableObject {
    public struct State: Equatable, Codable {
        public var months: [WalkMonth] = []
        public var walks: [WalkRouteSummary] = []
        public var selectedWalk: WalkRouteSummary? = nil
        public var filter: WalkSearchFilter = WalkSearchFilter()
        public var isLoading: Bool = false
        public var hasMore: Bool = false
        public var errorMessage: String? = nil
        public var selectedMonthID: Date? = nil
    }
    public enum Action: Equatable { case refresh(force: Bool); case selectMonth(Date?); case applyFilter(WalkSearchFilter); case clearFilter; case selectWalk(UUID?); case loadNextPage }
    @Published public private(set) var state = State()
    private let store: any AtlasDataSource
    private let pageSize: Int
    private var requestID = UUID()
    private var nextCursor: WalkRoutePageCursor?
    public init(store: any AtlasDataSource, pageSize: Int = 100) { self.store = store; self.pageSize = max(1, pageSize) }
    public var selectedMonth: WalkMonth? { state.months.first { $0.id == state.selectedMonthID } }
    public var months: [WalkMonth] { state.months }
    public var walks: [WalkRouteSummary] { state.walks }
    public var selectedWalk: WalkRouteSummary? { state.selectedWalk }
    public var filter: WalkSearchFilter { get { state.filter } set { state.filter = newValue } }
    public var isLoading: Bool { state.isLoading }
    public var hasMore: Bool { state.hasMore }
    public var errorMessage: String? { state.errorMessage }
    public var selectedMonthID: Date? { get { state.selectedMonthID } set { state.selectedMonthID = newValue } }
    public var isFiltering: Bool { state.filter.isActive }
    public func refresh(force: Bool = false) async {
        await store.waitUntilReady()
        state.errorMessage = nil
        do {
            let previous = state.selectedMonthID
            let refreshed = try await store.fetchWalkMonths(calendar: .current)
            state.months = refreshed
            if let previous, refreshed.contains(where: { $0.id == previous }) { state.selectedMonthID = previous } else { state.selectedMonthID = refreshed.first?.id }
            if force || previous != state.selectedMonthID || state.walks.isEmpty { await loadFirstPage() }
        } catch { state.errorMessage = "Couldn’t load walk months: \(error.localizedDescription)" }
    }
    public func selectMonth(_ id: Date?) async { state.selectedMonthID = id; if state.filter.isActive { state.filter = WalkSearchFilter() }; await loadFirstPage() }
    public func apply(filter: WalkSearchFilter) async { state.filter = filter; await loadFirstPage() }
    public func clearFilter() async { state.filter = WalkSearchFilter(); await loadFirstPage() }
    public func selectWalk(_ summary: WalkRouteSummary?) { state.selectedWalk = summary }
    public func loadRoute(id: UUID) async throws -> WalkRoute? { try await store.fetchRoute(id: id) }
    public func loadFirstPage() async {
        let currentRequest = UUID(); requestID = currentRequest
        state.isLoading = true; state.errorMessage = nil; nextCursor = nil; state.hasMore = false
        do {
            let page = try await store.fetchRouteSummaryPage(limit: pageSize, before: nil, in: state.filter.isActive ? nil : selectedMonth, filter: state.filter.isActive ? state.filter : nil)
            guard requestID == currentRequest else { return }
            state.walks = page.summaries; nextCursor = page.nextCursor; state.hasMore = page.hasMore
            if let sid = state.selectedWalk?.id, let refreshed = page.summaries.first(where: { $0.id == sid }) { state.selectedWalk = refreshed }
            state.isLoading = false
        } catch {
            guard requestID == currentRequest else { return }
            state.isLoading = false; state.hasMore = false; state.errorMessage = "Couldn’t load walks: \(error.localizedDescription)"
        }
    }
    /// Loads the whole archive in one pass. Atlas draws every route on one map,
    /// so month paging is the wrong default here.
    public func loadAll() async {
        let currentRequest = UUID(); requestID = currentRequest
        state.isLoading = true; state.errorMessage = nil
        var collected: [WalkRouteSummary] = []
        var cursor: WalkRoutePageCursor?
        do {
            while true {
                let page = try await store.fetchRouteSummaryPage(
                    limit: pageSize,
                    before: cursor,
                    in: nil,
                    filter: state.filter.isActive ? state.filter : nil
                )
                guard requestID == currentRequest else { return }
                collected.append(contentsOf: page.summaries)
                guard page.hasMore, let next = page.nextCursor else { break }
                cursor = next
            }
            state.walks = collected
            state.hasMore = false
            state.isLoading = false
        } catch {
            guard requestID == currentRequest else { return }
            state.isLoading = false
            state.errorMessage = "Couldn’t load walks: \(error.localizedDescription)"
        }
    }
    public func loadNextPage() async {        guard state.hasMore, let cursor = nextCursor, !state.isLoading else { return }
        let currentRequest = requestID; state.isLoading = true
        do {
            let page = try await store.fetchRouteSummaryPage(limit: pageSize, before: cursor, in: state.filter.isActive ? nil : selectedMonth, filter: state.filter.isActive ? state.filter : nil)
            guard requestID == currentRequest else { return }
            var known = Set(state.walks.map(\.id))
            state.walks.append(contentsOf: page.summaries.filter { known.insert($0.id).inserted })
            nextCursor = page.nextCursor; state.hasMore = page.hasMore; state.isLoading = false
        } catch {
            guard requestID == currentRequest else { return }
            state.hasMore = false; state.isLoading = false; state.errorMessage = "Couldn’t load more walks: \(error.localizedDescription)"
        }
    }
    public func send(_ action: Action) async {
        switch action {
        case .refresh(let force): await refresh(force: force)
        case .selectMonth(let id): await selectMonth(id)
        case .applyFilter(let f): await apply(filter: f)
        case .clearFilter: await clearFilter()
        case .selectWalk(let id):
            if let id { state.selectedWalk = state.walks.first { $0.id == id } } else { state.selectedWalk = nil }
        case .loadNextPage: await loadNextPage()
        }
    }
}

// MARK: - Places ViewModel

@MainActor
public final class PlacesViewModel: ObservableObject {
    public struct State: Equatable, Codable {
        public var places: [Place] = []
        public var selectedPlace: Place? = nil
        public var isLoading: Bool = false
        public var errorMessage: String? = nil
        /// The last Apple Maps query and its results.
        public var query: String = ""
        public var results: [PlaceSearchResult] = []
        public var isSearching: Bool = false
    }
    public enum Action: Equatable {
        case refresh
        case select(UUID?)
        case add(Place)
        case delete(UUID)
        case search(String)
        case saveResult(Int)
        case clearResults
    }
    @Published public private(set) var state = State()
    private let store: any AtlasDataSource
    private let searcher: any PlaceSearching
    /// Guards against a slow response overwriting a newer one.
    private var searchToken = 0

    public init(store: any AtlasDataSource, searcher: any PlaceSearching = MapKitPlaceSearch()) {
        self.store = store
        self.searcher = searcher
    }
    public var places: [Place] { state.places }
    public var selectedPlace: Place? { state.selectedPlace }
    public var isLoading: Bool { state.isLoading }
    public var errorMessage: String? { state.errorMessage }
    public var results: [PlaceSearchResult] { state.results }
    public var isSearching: Bool { state.isSearching }
    public var query: String { state.query }
    public func refresh() async {
        state.isLoading = true; state.errorMessage = nil
        do { state.places = try await store.fetchPlaces(); state.isLoading = false }
        catch { state.isLoading = false; state.errorMessage = error.localizedDescription }
    }
    public func select(_ place: Place?) { state.selectedPlace = place }
    public func add(_ place: Place) async { try? await store.savePlace(place); await refresh() }
    public func delete(id: UUID) async { try? await store.deletePlace(id: id); if state.selectedPlace?.id == id { state.selectedPlace = nil }; await refresh() }

    /// Search Apple Maps. The map's own centre biases the results without
    /// restricting them.
    public func search(_ text: String, near: GeoCoordinate? = nil, limit: Int = 20) async {
        searchToken &+= 1
        let token = searchToken
        state.query = text
        state.errorMessage = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.results = []
            state.isSearching = false
            return
        }
        state.isSearching = true
        do {
            let found = try await searcher.search(trimmed, near: near, limit: limit)
            guard token == searchToken else { return }
            state.results = found
            state.isSearching = false
        } catch {
            guard token == searchToken else { return }
            state.results = []
            state.isSearching = false
            state.errorMessage = error.localizedDescription
        }
    }

    /// Save a search result. The same place saved twice updates the place
    /// instead of adding a duplicate.
    @discardableResult
    public func save(result: PlaceSearchResult) async -> Place? {
        let place = resolvedPlace(for: result)
        do {
            try await store.savePlace(place)
            await refresh()
            return place
        } catch {
            state.errorMessage = error.localizedDescription
            return nil
        }
    }

    /// The place a result becomes when saved: a new place, or the existing
    /// one it stands for. Identity is the name plus the doorstep, so saving
    /// a place the archive already holds updates it rather than duplicating
    /// it — the archive and Apple rarely agree on the last decimal of a
    /// coordinate.
    public func resolvedPlace(for result: PlaceSearchResult) -> Place {
        let fresh = result.makePlace()
        guard let existing = existingMatch(for: result) else { return fresh }
        return Place(
            id: existing.id,
            name: fresh.name,
            coordinate: fresh.coordinate,
            note: fresh.note,
            createdAt: existing.createdAt
        )
    }

    /// The saved place a search result stands for, if any.
    private func existingMatch(for result: PlaceSearchResult) -> Place? {
        let target = result.coordinate
        let scale = cos(target.latitude * .pi / 180) * 111_320
        return state.places.first { place in
            guard place.name.compare(
                result.name,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame else { return false }
            let dLat = (place.coordinate.latitude - target.latitude) * 111_320
            let dLon = (place.coordinate.longitude - target.longitude) * scale
            return (dLat * dLat + dLon * dLon) < 50 * 50
        }
    }

    @discardableResult
    public func save(resultAt index: Int) async -> Place? {
        guard state.results.indices.contains(index) else { return nil }
        return await save(result: state.results[index])
    }

    /// Whether a result is already in the saved list.
    public func isSaved(_ result: PlaceSearchResult) -> Bool {
        existingMatch(for: result) != nil || state.places.contains { $0.id == result.makePlace().id }
    }

    public func clearResults() {
        searchToken &+= 1
        state.query = ""
        state.results = []
        state.isSearching = false
    }

    public func send(_ action: Action) async {
        switch action {
        case .refresh: await refresh()
        case .select(let id): state.selectedPlace = id.flatMap { iid in state.places.first { $0.id == iid } }
        case .add(let p): await add(p)
        case .delete(let id): await delete(id: id)
        case .search(let text): await search(text)
        case .saveResult(let index): await save(resultAt: index)
        case .clearResults: clearResults()
        }
    }
}

// MARK: - Flights ViewModel (stub)

@MainActor
public final class FlightsViewModel: ObservableObject {
    public struct State: Equatable, Codable { public var flights: [Flight] = []; public var isLoading: Bool = false; public var errorMessage: String? = nil }
    public enum Action: Equatable { case refresh }
    @Published public private(set) var state = State()
    private let store: any AtlasDataSource
    public init(store: any AtlasDataSource) { self.store = store }
    public var flights: [Flight] { state.flights }
    public var isLoading: Bool { state.isLoading }
    public var errorMessage: String? { state.errorMessage }
    public func refresh() async { state.isLoading = true; do { state.flights = try await store.fetchFlights(); state.isLoading = false } catch { state.isLoading = false; state.errorMessage = error.localizedDescription } }
    public func send(_ action: Action) async { if case .refresh = action { await refresh() } }
}

// MARK: - Parcels ViewModel (stub)

@MainActor
public final class ParcelsViewModel: ObservableObject {
    public struct State: Equatable, Codable { public var parcels: [Parcel] = []; public var isLoading: Bool = false; public var errorMessage: String? = nil }
    public enum Action: Equatable { case refresh }
    @Published public private(set) var state = State()
    private let store: any AtlasDataSource
    public init(store: any AtlasDataSource) { self.store = store }
    public var parcels: [Parcel] { state.parcels }
    public var isLoading: Bool { state.isLoading }
    public var errorMessage: String? { state.errorMessage }
    public func refresh() async { state.isLoading = true; do { state.parcels = try await store.fetchParcels(); state.isLoading = false } catch { state.isLoading = false; state.errorMessage = error.localizedDescription } }
    public func send(_ action: Action) async { if case .refresh = action { await refresh() } }
}

// MARK: - TFL ViewModel (stub)

@MainActor
public final class TFLViewModel: ObservableObject {
    public struct State: Equatable, Codable { public var stations: [TFLStation] = []; public var isLoading: Bool = false; public var errorMessage: String? = nil }
    public enum Action: Equatable { case refresh }
    @Published public private(set) var state = State()
    private let store: any AtlasDataSource
    public init(store: any AtlasDataSource) { self.store = store }
    public var stations: [TFLStation] { state.stations }
    public var isLoading: Bool { state.isLoading }
    public var errorMessage: String? { state.errorMessage }
    public func refresh() async { state.isLoading = true; do { state.stations = try await store.fetchTFLStations(); state.isLoading = false } catch { state.isLoading = false; state.errorMessage = error.localizedDescription } }
    public func send(_ action: Action) async { if case .refresh = action { await refresh() } }
}
// MARK: - Cameras (live TfL JamCams)

@MainActor
public final class CamerasViewModel: ObservableObject {
    public struct State: Equatable, Codable {
        public var cameras: [JamCam] = []
        public var selectedID: String? = nil
        public var isLoading: Bool = false
        public var errorMessage: String? = nil
        public var lastUpdated: Date? = nil
    }
    public enum Action: Equatable { case refresh(force: Bool); case select(String?) }

    @Published public private(set) var state = State()
    private let provider: any JamCamProviding
    private let maximumAge: TimeInterval

    public init(provider: any JamCamProviding = TFLJamCamClient(), maximumAge: TimeInterval = 240) {
        self.provider = provider
        self.maximumAge = maximumAge
    }

    public var cameras: [JamCam] { state.cameras }
    public var selectedCamera: JamCam? {
        guard let id = state.selectedID else { return nil }
        return state.cameras.first { $0.id == id }
    }
    public var selectedID: String? { state.selectedID }
    public var isLoading: Bool { state.isLoading }
    public var errorMessage: String? { state.errorMessage }
    public var lastUpdated: Date? { state.lastUpdated }
    public var onlineCount: Int { state.cameras.lazy.filter(\.isAvailable).count }

    /// Stable centre of the live network, used to order the nearby-camera dock.
    public var coverageCenter: GeoCoordinate {
        guard !state.cameras.isEmpty else {
            return GeoCoordinate(latitude: 51.5074, longitude: -0.1278)
        }
        let count = Double(state.cameras.count)
        let latitude = state.cameras.reduce(0) { $0 + $1.coordinate.latitude } / count
        let longitude = state.cameras.reduce(0) { $0 + $1.coordinate.longitude } / count
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }
    public var isStale: Bool {
        guard let last = state.lastUpdated else { return true }
        return Date().timeIntervalSince(last) > maximumAge
    }

    public func refresh(force: Bool = false) async {
        guard !state.isLoading else { return }
        if !force, !state.cameras.isEmpty, !isStale { return }

        state.isLoading = true
        state.errorMessage = nil
        let started = Date()
        do {
            let cameras = try await provider.fetchCameras()
            state.cameras = cameras
            state.lastUpdated = .now
            state.isLoading = false
            if let id = state.selectedID, !cameras.contains(where: { $0.id == id }) {
                state.selectedID = nil
            }
            AtlasPerformance.shared.record(
                "cameras.fetch",
                milliseconds: Date().timeIntervalSince(started) * 1_000
            )
            AtlasPerformance.shared.increment("cameras.loaded", by: Double(cameras.count))
        } catch {
            state.isLoading = false
            state.errorMessage = "Couldn't load TfL cameras: \(error.localizedDescription)"
            AtlasPerformance.shared.increment("cameras.errors")
        }
    }

    /// The coverage grid fades into individual cameras below this map height
    /// (~9 km). Above it, 889 dots collapse into an unreadable rash.
    public static let dotLayerMaximumSpan: Double = 0.085
    /// A hard ceiling keeps a dense junction from paying for hundreds of
    /// MapCircle overlays; the nearest cameras win.
    public static let dotLayerLimit = 200

    /// Cameras drawn as individual dots for this viewport, nearest first.
    /// The box is the viewport plus 30% on each side so a camera does not
    /// pop in the moment it crosses the edge.
    public func dots(in region: GeoRegion, limit: Int = CamerasViewModel.dotLayerLimit) -> [JamCam] {
        Self.dots(from: state.cameras, in: region, limit: limit)
    }

    /// Pure form of `dots(in:limit:)` for the map's live dot canvas, which
    /// recomputes the set every frame instead of holding it as state.
    public static func dots(
        from cameras: [JamCam],
        in region: GeoRegion,
        limit: Int = CamerasViewModel.dotLayerLimit
    ) -> [JamCam] {
        guard region.latitudeDelta < dotLayerMaximumSpan else { return [] }

        let center = region.center
        let latitudeLimit = region.latitudeDelta * 0.8
        let longitudeLimit = region.longitudeDelta * 0.8
        let cosLatitude = cos(center.latitude * .pi / 180)

        return cameras
            .compactMap { camera -> (JamCam, Double)? in
                let dLat = camera.coordinate.latitude - center.latitude
                let dLon = camera.coordinate.longitude - center.longitude
                guard abs(dLat) <= latitudeLimit, abs(dLon) <= longitudeLimit else { return nil }
                let scaledLon = dLon * cosLatitude
                return (camera, dLat * dLat + scaledLon * scaledLon)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    public func refreshIfNeeded() async { await refresh(force: false) }
    public func select(_ id: String?) { state.selectedID = id }
    public func selectFirstAvailable() {
        state.selectedID = (state.cameras.first(where: \.isAvailable) ?? state.cameras.first)?.id
    }

    public func send(_ action: Action) async {
        switch action {
        case .refresh(let force): await refresh(force: force)
        case .select(let id): select(id)
        }
    }
}
