import Foundation
import CoreLocation

@MainActor
public protocol AtlasDataSource: AnyObject {
    func waitUntilReady() async
    // Walks
    func fetchWalkMonths(calendar: Calendar) async throws -> [WalkMonth]
    func fetchRouteSummaryPage(limit: Int, before: WalkRoutePageCursor?, in month: WalkMonth?, filter: WalkSearchFilter?) async throws -> WalkRouteSummaryPage
    func fetchRoute(id: UUID) async throws -> WalkRoute?
    // Places
    func fetchPlaces() async throws -> [Place]
    func savePlace(_ place: Place) async throws
    func deletePlace(id: UUID) async throws
    // Flights / Parcels / TFL
    func fetchFlights() async throws -> [Flight]
    func fetchParcels() async throws -> [Parcel]
    func fetchTFLStations() async throws -> [TFLStation]
}

@MainActor
public final class InMemoryAtlasStore: AtlasDataSource {
    private var walks: [WalkRouteSummary] = []
    private var routes: [UUID: WalkRoute] = [:]
    private var places: [Place] = []
    private var flights: [Flight] = []
    private var parcels: [Parcel] = []
    private var stations: [TFLStation] = []

    public init(seed: Bool = true) {
        if seed { Self.seed(into: self) }
    }

    public func waitUntilReady() async {}

    // Walks
    public func fetchWalkMonths(calendar: Calendar = .current) async throws -> [WalkMonth] {
        WalkMonth.group(startDates: walks.map(\.startDate))
    }
    public func fetchRouteSummaryPage(limit: Int, before cursor: WalkRoutePageCursor?, in month: WalkMonth?, filter: WalkSearchFilter?) async throws -> WalkRouteSummaryPage {
        var list = walks.sorted { $0.startDate > $1.startDate }
        if let month { list = list.filter { $0.startDate >= month.startDate && $0.startDate < month.endDate } }
        if let filter { list = list.filter { filter.matches($0) } }
        if let cursor { list = list.filter { $0.startDate < cursor.startDate || ($0.startDate == cursor.startDate && $0.id.uuidString < cursor.id.uuidString) } }
        let page = Array(list.prefix(limit))
        let hasMore = list.count > limit
        let next = hasMore && !page.isEmpty ? WalkRoutePageCursor(startDate: page.last!.startDate, id: page.last!.id) : nil
        return WalkRouteSummaryPage(summaries: page, nextCursor: next, hasMore: hasMore)
    }
    public func fetchRoute(id: UUID) async throws -> WalkRoute? { routes[id] }

    // Places
    public func fetchPlaces() async throws -> [Place] { places }
    public func savePlace(_ place: Place) async throws {
        if let i = places.firstIndex(where: { $0.id == place.id }) { places[i] = place } else { places.append(place) }
    }
    public func deletePlace(id: UUID) async throws { places.removeAll { $0.id == id } }

    // Flights / Parcels / TFL
    public func fetchFlights() async throws -> [Flight] { FileAtlasStore.ordered(flights) }
    public func fetchParcels() async throws -> [Parcel] { parcels }
    public func fetchTFLStations() async throws -> [TFLStation] { stations }

    // MARK: Seed
    private static func seed(into store: InMemoryAtlasStore) {
        let now = Date()

        // Walks — each summary gets a real route so the map has something to draw.
        var routes: [UUID: WalkRoute] = [:]

        func makeWalk(title: String, center: CLLocationCoordinate2D, radius: Double,
                      start: Date, duration: TimeInterval) -> WalkRouteSummary {
            let id = UUID()
            let end = start.addingTimeInterval(duration)
            routes[id] = loopRoute(id: id, center: center, radius: radius, start: start, end: end, points: 180)
            return WalkRouteSummary(id: id, startDate: start, endDate: end, hasGPSRoute: true, title: title)
        }

        store.walks = [
            makeWalk(title: "Hyde Park loop",
                     center: CLLocationCoordinate2D(latitude: 51.5073, longitude: -0.1657),
                     radius: 0.0105, start: now.addingTimeInterval(-3 * 3600), duration: 3_180),
            makeWalk(title: "South Bank",
                     center: CLLocationCoordinate2D(latitude: 51.5076, longitude: -0.1198),
                     radius: 0.0072, start: now.addingTimeInterval(-27 * 3600), duration: 2_340),
            makeWalk(title: "Hampstead Heath",
                     center: CLLocationCoordinate2D(latitude: 51.5608, longitude: -0.1640),
                     radius: 0.0135, start: now.addingTimeInterval(-4 * 86_400), duration: 4_560),
        ]
        store.routes = routes

        // Places
        store.places = [
            Place(name: "Home", coordinate: CLLocationCoordinate2D(latitude: 51.5007, longitude: -0.1246), note: "Base camp"),
            Place(name: "Office", coordinate: CLLocationCoordinate2D(latitude: 51.5105, longitude: -0.0865), note: "The studio"),
            Place(name: "Tate Modern", coordinate: CLLocationCoordinate2D(latitude: 51.5076, longitude: -0.0994), note: "Sunday favourite"),
            Place(name: "Regent's Park", coordinate: CLLocationCoordinate2D(latitude: 51.5313, longitude: -0.1569), note: "Loop from the flat"),
            Place(name: "Borough Market", coordinate: CLLocationCoordinate2D(latitude: 51.5055, longitude: -0.0910), note: "Lunch spot"),
        ]

        // Flights
        store.flights = [
            Flight(number: "BA117", origin: "LHR", destination: "JFK",
                   departure: now.addingTimeInterval(26 * 3_600),
                   arrival: now.addingTimeInterval(26 * 3_600 + 7 * 3_600 + 55 * 60)),
            Flight(number: "BA245", origin: "LHR", destination: "GRU",
                   departure: now.addingTimeInterval(11 * 86_400),
                   arrival: now.addingTimeInterval(11 * 86_400 + 11 * 3_600 + 40 * 60)),
        ]

        // Parcels
        store.parcels = [
            Parcel(trackingNumber: "1Z999AA10123456784", carrier: "UPS", status: "In transit",
                   lastLocation: CLLocationCoordinate2D(latitude: 52.4862, longitude: -1.8904),
                   updatedAt: now.addingTimeInterval(-2 * 3_600)),
            Parcel(trackingNumber: "DPD-4482-9107", carrier: "DPD", status: "Out for delivery",
                   lastLocation: CLLocationCoordinate2D(latitude: 51.5142, longitude: -0.0931),
                   updatedAt: now.addingTimeInterval(-18 * 60)),
        ]

        // TFL
        store.stations = [
            TFLStation(id: "940GZZLUOXC", name: "Oxford Circus",
                       coordinate: CLLocationCoordinate2D(latitude: 51.5152, longitude: -0.1419),
                       lines: ["Central", "Bakerloo", "Victoria"]),
            TFLStation(id: "940GZZLUKSX", name: "King's Cross St Pancras",
                       coordinate: CLLocationCoordinate2D(latitude: 51.5308, longitude: -0.1238),
                       lines: ["Northern", "Piccadilly", "Victoria", "Circle", "Metropolitan", "Hammersmith & City"]),
            TFLStation(id: "940GZZLUWLO", name: "Waterloo",
                       coordinate: CLLocationCoordinate2D(latitude: 51.5036, longitude: -0.1143),
                       lines: ["Bakerloo", "Northern", "Jubilee", "Waterloo & City"]),
            TFLStation(id: "940GZZLULVT", name: "Liverpool Street",
                       coordinate: CLLocationCoordinate2D(latitude: 51.5178, longitude: -0.0823),
                       lines: ["Central", "Circle", "Metropolitan", "Hammersmith & City", "Elizabeth"]),
            TFLStation(id: "940GZZLUPAC", name: "Paddington",
                       coordinate: CLLocationCoordinate2D(latitude: 51.5154, longitude: -0.1755),
                       lines: ["Bakerloo", "Circle", "District", "Hammersmith & City", "Elizabeth"]),
            TFLStation(id: "940GZZLUCYF", name: "Canary Wharf",
                       coordinate: CLLocationCoordinate2D(latitude: 51.5036, longitude: -0.0189),
                       lines: ["Jubilee", "Elizabeth"]),
        ]
    }

    /// A closed, gently wandering loop around a centre point.
    private static func loopRoute(id: UUID, center: CLLocationCoordinate2D, radius: Double,
                                  start: Date, end: Date, points: Int) -> WalkRoute {
        let steps = max(12, points)
        let duration = max(1, end.timeIntervalSince(start))
        let longitudeScale = 1 / max(0.2, cos(center.latitude * .pi / 180))
        var locations: [RouteLocation] = []
        locations.reserveCapacity(steps + 1)

        for index in 0...steps {
            let t = Double(index) / Double(steps)
            let angle = t * 2 * .pi
            let wobble = 1 + 0.12 * sin(angle * 3)
            let latitude = center.latitude + radius * wobble * cos(angle)
            let longitude = center.longitude + radius * wobble * sin(angle) * longitudeScale
            let elevation = 18 + 12 * sin(angle * 2) + 4 * cos(angle * 5)
            locations.append(RouteLocation(
                latitude: latitude,
                longitude: longitude,
                elevation: elevation,
                timestamp: start.addingTimeInterval(duration * t)
            ))
        }

        return WalkRoute(id: id, startDate: start, endDate: end, locations: locations)
    }
}