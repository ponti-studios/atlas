import Foundation
import CoreLocation

/// A complete, portable Atlas snapshot. Written by the importer, read by the app.
public struct AtlasData: Codable, Sendable {
    public var walks: [WalkRouteSummary]
    public var routes: [WalkRoute]
    public var places: [Place]
    public var flights: [Flight]
    public var parcels: [Parcel]
    public var stations: [TFLStation]

    public init(
        walks: [WalkRouteSummary] = [],
        routes: [WalkRoute] = [],
        places: [Place] = [],
        flights: [Flight] = [],
        parcels: [Parcel] = [],
        stations: [TFLStation] = []
    ) {
        self.walks = walks
        self.routes = routes
        self.places = places
        self.flights = flights
        self.parcels = parcels
        self.stations = stations
    }

    public var pointCount: Int { routes.reduce(0) { $0 + $1.locations.count } }
}

// MARK: - Where real data lives

public enum AtlasDataLocation {
    /// `ATLAS_DATA_FILE` wins so both the CLI and a simulator launch can point
    /// at any snapshot without moving files around.
    public static var overrideFile: URL? {
        guard let path = ProcessInfo.processInfo.environment["ATLAS_DATA_FILE"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    public static func defaultDataFile() -> URL {
        #if os(macOS)
        let base = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Atlas", isDirectory: true)
        #else
        let base = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("atlas-data.json")
    }

    public static func existingDataFile() -> URL? {
        if let overrideFile { return FileManager.default.fileExists(atPath: overrideFile.path) ? overrideFile : nil }
        let candidate = defaultDataFile()
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

public enum AtlasStoreFactory {
    /// Real imported data when available, seeded demo data otherwise.
    @MainActor
    public static func make() -> any AtlasDataSource {
        if let url = AtlasDataLocation.existingDataFile() {
            NSLog("Atlas: loading %@", url.path)
            let store = FileAtlasStore(url: url)
            // Start the background decode immediately, before SwiftUI/MapKit
            // scene setup blocks the main actor.
            store.prefetch()
            return store
        }
        NSLog("Atlas: no data file at %@; using seeded demo data", AtlasDataLocation.defaultDataFile().path)
        return InMemoryAtlasStore(seed: true)
    }
}

// MARK: - File-backed store

/// The places a person saved in the app. Kept beside the imported snapshot
/// rather than inside it: the snapshot is machine-generated and rebuilt on
/// every import, this file is the user's, and the two must not fight.
public struct SavedPlaces: Codable, Sendable, Equatable {
    public var places: [Place] = []
    /// Imported places the user deleted.
    public var removed: [UUID] = []

    public init(places: [Place] = [], removed: [UUID] = []) {
        self.places = places
        self.removed = removed
    }
}

@MainActor
public final class FileAtlasStore: AtlasDataSource {
    public let url: URL
    /// The user's saved places, next to the snapshot.
    public let savedPlacesURL: URL
    private var data: AtlasData?
    private var routes: [UUID: WalkRoute] = [:]
    private var decodeTask: Task<AtlasData, Never>?
    private var saved: SavedPlaces?

    public init(url: URL, savedPlacesURL: URL? = nil) {
        self.url = url
        self.savedPlacesURL = savedPlacesURL ?? url.deletingLastPathComponent()
            .appendingPathComponent("atlas-places.json")
    }

    /// Kick off the decode on a background thread. Safe to call repeatedly.
    public func prefetch() {
        guard data == nil, decodeTask == nil else { return }
        AtlasPerformance.shared.begin("snapshot.decode")
        let url = self.url
        decodeTask = Task.detached(priority: .userInitiated) {
            let decoded: AtlasData
            do {
                let raw = try Data(contentsOf: url)
                decoded = try JSONDecoder().decode(AtlasData.self, from: raw)
            } catch {
                NSLog("Atlas: could not read %@: %@", url.path, String(describing: error))
                decoded = AtlasData()
            }
            AtlasPerformance.shared.end("snapshot.decode")
            AtlasPerformance.shared.mark("snapshot.decoded")
            return decoded
        }
    }

    /// Decode off the main thread; large archives are tens of megabytes.
    public func waitUntilReady() async {
        guard data == nil else { return }
        prefetch()
        guard let decodeTask else { return }
        let decoded = await decodeTask.value
        self.decodeTask = nil
        NSLog("Atlas: loaded %d walks, %d places, %d flights", decoded.walks.count, decoded.places.count, decoded.flights.count)
        install(decoded)
    }

    private func install(_ snapshot: AtlasData) {
        data = snapshot
        routes = Dictionary(snapshot.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var snapshot: AtlasData {
        if let data { return data }
        // A caller that skipped `waitUntilReady` gets an empty view rather than a crash.
        if let raw = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AtlasData.self, from: raw) {
            install(decoded)
            return decoded
        }
        return AtlasData()
    }

    // Walks
    public func fetchWalkMonths(calendar: Calendar = .current) async throws -> [WalkMonth] {
        WalkMonth.group(startDates: snapshot.walks.map(\.startDate), calendar: calendar)
    }

    public func fetchRouteSummaryPage(
        limit: Int,
        before cursor: WalkRoutePageCursor?,
        in month: WalkMonth?,
        filter: WalkSearchFilter?
    ) async throws -> WalkRouteSummaryPage {
        var list = snapshot.walks.sorted { $0.startDate > $1.startDate }
        if let month { list = list.filter { $0.startDate >= month.startDate && $0.startDate < month.endDate } }
        if let filter { list = list.filter { filter.matches($0) } }
        if let cursor {
            list = list.filter {
                $0.startDate < cursor.startDate || ($0.startDate == cursor.startDate && $0.id.uuidString < cursor.id.uuidString)
            }
        }
        let page = Array(list.prefix(limit))
        let hasMore = list.count > limit
        let next = hasMore && !page.isEmpty
            ? WalkRoutePageCursor(startDate: page.last!.startDate, id: page.last!.id)
            : nil
        return WalkRouteSummaryPage(summaries: page, nextCursor: next, hasMore: hasMore)
    }

    public func fetchRoute(id: UUID) async throws -> WalkRoute? { routes[id] }

    // Places
    /// Imported places, minus the ones the user deleted, plus the ones the
    /// user saved. A saved place wins over an imported one with the same id.
    public func fetchPlaces() async throws -> [Place] {
        let removed = Set(savedPlaces.removed)
        var merged = snapshot.places.filter { !removed.contains($0.id) }
        let userIDs = Set(savedPlaces.places.map(\.id))
        merged.removeAll { userIDs.contains($0.id) }
        merged.append(contentsOf: savedPlaces.places)
        return merged
    }

    public func savePlace(_ place: Place) async throws {
        var saved = savedPlaces
        if let index = saved.places.firstIndex(where: { $0.id == place.id }) {
            saved.places[index] = place
        } else {
            saved.places.append(place)
        }
        // Saving over an imported place hides the imported copy.
        if snapshot.places.contains(where: { $0.id == place.id }) {
            if !saved.removed.contains(place.id) { saved.removed.append(place.id) }
        }
        try write(saved)
    }

    public func deletePlace(id: UUID) async throws {
        var saved = savedPlaces
        saved.places.removeAll { $0.id == id }
        if snapshot.places.contains(where: { $0.id == id }), !saved.removed.contains(id) {
            saved.removed.append(id)
        }
        try write(saved)
    }

    /// The user's saved places, as stored.
    private var savedPlaces: SavedPlaces {
        if let saved { return saved }
        let loaded: SavedPlaces
        if let raw = try? Data(contentsOf: savedPlacesURL),
           let decoded = try? JSONDecoder().decode(SavedPlaces.self, from: raw) {
            loaded = decoded
        } else {
            loaded = SavedPlaces()
        }
        saved = loaded
        return loaded
    }

    /// Write the user's places atomically: a half-written file would lose
    /// saved work.
    private func write(_ saved: SavedPlaces) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let payload = try encoder.encode(saved)
        try FileManager.default.createDirectory(
            at: savedPlacesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: savedPlacesURL, options: [.atomic])
        self.saved = saved
    }

    // Flights / Parcels / TFL
    public func fetchFlights() async throws -> [Flight] { Self.ordered(snapshot.flights) }

    /// Upcoming legs soonest-first, then past legs most-recent-first.
    static func ordered(_ flights: [Flight]) -> [Flight] {
        let now = Date()
        return flights.sorted { lhs, rhs in
            let lhsUpcoming = lhs.departure >= now
            let rhsUpcoming = rhs.departure >= now
            if lhsUpcoming != rhsUpcoming { return lhsUpcoming }
            return lhsUpcoming ? lhs.departure < rhs.departure : lhs.departure > rhs.departure
        }
    }
    public func fetchParcels() async throws -> [Parcel] { snapshot.parcels }
    public func fetchTFLStations() async throws -> [TFLStation] { snapshot.stations }
}
