import Foundation

/// One workout read from Health, in the shape the archive understands.
///
/// Deliberately plain data: the HealthKit queries live in the app target, so
/// the conversion and the merging can be tested without a device or a
/// permission sheet.
public struct HealthWorkout: Sendable, Equatable {
    public let id: UUID
    public let start: Date
    public let end: Date
    /// `HKWorkoutActivityType`, reduced to a word ("walking", "running").
    public let activity: String?
    public let locations: [RouteLocation]

    public init(id: UUID, start: Date, end: Date, activity: String?, locations: [RouteLocation]) {
        self.id = id
        self.start = start
        self.end = end
        self.activity = activity
        self.locations = locations
    }
}

/// The walks that came from Health. A sidecar, like `atlas-places.json`: an
/// import rebuilds the snapshot, and the sync writes here, so neither can
/// destroy the other.
public struct HealthWalkArchive: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var lastSyncedAt: Date?
    public var walks: [WalkRouteSummary] = []
    public var routes: [WalkRoute] = []

    public init(
        version: Int = 1,
        lastSyncedAt: Date? = nil,
        walks: [WalkRouteSummary] = [],
        routes: [WalkRoute] = []
    ) {
        self.version = version
        self.lastSyncedAt = lastSyncedAt
        self.walks = walks
        self.routes = routes
    }

    public var fileName: String { "atlas-health.json" }

    public static func url(beside snapshot: URL) -> URL {
        snapshot.deletingLastPathComponent().appendingPathComponent("atlas-health.json")
    }

    public static func load(from url: URL) -> HealthWalkArchive {
        guard let raw = try? Data(contentsOf: url) else { return HealthWalkArchive() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(HealthWalkArchive.self, from: raw) else {
            return HealthWalkArchive()
        }
        return archive
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: url, options: [.atomic])
    }

    /// A route needs at least two points to be drawable; a workout without one
    /// still belongs in the list, just without a line on the map.
    public static func hasRoute(_ locations: [RouteLocation]) -> Bool { locations.count > 1 }

    /// Folds this sync into the archive. Workouts that were not in this batch
    /// are kept, and a re-synced workout replaces its older copy.
    public static func merging(
        _ workouts: [HealthWorkout],
        into archive: HealthWalkArchive,
        syncedAt: Date = Date()
    ) -> HealthWalkArchive {
        var walks = Dictionary(archive.walks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var routes = Dictionary(archive.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for workout in workouts {
            let id = workout.id
            let points = workout.locations
            // A workout with no route cannot be drawn, so it is not a walk
            // this app can show. Skip it rather than list a dead card.
            guard hasRoute(points), let bounds = GeoBounds(points: points.map({ GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) })) else { continue }
            let coordinates = points.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            walks[id] = WalkRouteSummary(
                id: id,
                startDate: workout.start,
                endDate: workout.end,
                hasGPSRoute: true,
                title: nil,
                activity: workout.activity,
                bounds: bounds,
                pointCount: points.count,
                distanceMeters: RouteGeometry.length(coordinates)
            )
            routes[id] = WalkRoute(id: id, startDate: workout.start, endDate: workout.end, locations: points)
        }

        return HealthWalkArchive(
            version: archive.version,
            lastSyncedAt: syncedAt,
            walks: walks.values.sorted { $0.startDate > $1.startDate },
            routes: routes.values.sorted { $0.startDate > $1.startDate }
        )
    }

    /// The archive as a snapshot fragment, for merging into the loaded store.
    public var snapshot: AtlasData {
        AtlasData(walks: walks, routes: routes)
    }

    /// Repairs an archive written by an older build: drops walks that have no
    /// route, and fills in the geometry facts that summaries now carry.
    /// Returns nil when there is nothing to change, so callers can skip a write.
    public func normalized() -> HealthWalkArchive? {
        let routesByID = Dictionary(routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        var kept: [WalkRouteSummary] = []
        kept.reserveCapacity(walks.count)

        for walk in walks {
            guard walk.hasGPSRoute, let route = routesByID[walk.id] else {
                changed = true
                continue
            }
            if walk.bounds == nil {
                let coordinates = route.locations.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
                guard let bounds = GeoBounds(points: coordinates) else {
                    changed = true
                    continue
                }
                changed = true
                kept.append(WalkRouteSummary(
                    id: walk.id,
                    startDate: walk.startDate,
                    endDate: walk.endDate,
                    hasGPSRoute: true,
                    title: walk.title,
                    activity: walk.activity,
                    bounds: bounds,
                    pointCount: coordinates.count,
                    distanceMeters: RouteGeometry.length(coordinates)
                ))
            } else {
                kept.append(walk)
            }
        }

        guard changed else { return nil }
        let keptIDs = Set(kept.map(\.id))
        return HealthWalkArchive(
            version: version,
            lastSyncedAt: lastSyncedAt,
            walks: kept,
            routes: routes.filter { keptIDs.contains($0.id) }
        )
    }
}
