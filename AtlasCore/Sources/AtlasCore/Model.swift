import Foundation
import CoreLocation

// MARK: - Walks (ported from an earlier tracker)

public struct WalkRoute: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date
    public let locations: [RouteLocation]
    public init(id: UUID, startDate: Date, endDate: Date, locations: [RouteLocation]) {
        self.id = id; self.startDate = startDate; self.endDate = endDate; self.locations = locations
    }
    public var durationSeconds: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }
    public var duration: String { let m = max(1, Int(endDate.timeIntervalSince(startDate)/60)); return "\(m) min" }
    public var filename: String { "walk-\(Self.filenameDate.string(from: startDate)).gpx" }
    private static let filenameDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 0); return f
    }()

    /// The map only needs latitude/longitude. Per-point timestamps and elevation
    /// made the snapshot 7.6 MB and dominated decode time, so routes persist as
    /// one little-endian Float32 coordinate blob (~8 bytes per point, ~1 m
    /// precision) and synthesise evenly spaced timestamps on read. The legacy
    /// `locations` key still decodes, so an older snapshot keeps working.
    private enum CodingKeys: String, CodingKey {
        case id, startDate, endDate, coordinates, locations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        if let blob = try? container.decode(Data.self, forKey: .coordinates) {
            locations = Self.decodeCoordinates(blob, startDate: startDate, endDate: endDate)
        } else {
            locations = try container.decode([RouteLocation].self, forKey: .locations)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(endDate, forKey: .endDate)
        try container.encode(Self.encodeCoordinates(locations), forKey: .coordinates)
    }

    private static func encodeCoordinates(_ locations: [RouteLocation]) -> Data {
        var data = Data(capacity: locations.count * 8)
        for location in locations {
            var pair = (
                Float32(location.latitude).bitPattern.littleEndian,
                Float32(location.longitude).bitPattern.littleEndian
            )
            withUnsafeBytes(of: &pair) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decodeCoordinates(_ data: Data, startDate: Date, endDate: Date) -> [RouteLocation] {
        let count = data.count / 8
        guard count > 0 else { return [] }
        let step = count > 1 ? endDate.timeIntervalSince(startDate) / Double(count - 1) : 0
        var locations: [RouteLocation] = []
        locations.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let latitudeBits = raw.loadUnaligned(fromByteOffset: index * 8, as: UInt32.self)
                let longitudeBits = raw.loadUnaligned(fromByteOffset: index * 8 + 4, as: UInt32.self)
                let latitude = Float32(bitPattern: UInt32(littleEndian: latitudeBits))
                let longitude = Float32(bitPattern: UInt32(littleEndian: longitudeBits))
                locations.append(RouteLocation(
                    latitude: Double(latitude),
                    longitude: Double(longitude),
                    elevation: nil,
                    timestamp: startDate.addingTimeInterval(step * Double(index))
                ))
            }
        }
        return locations
    }
}

public struct RouteLocation: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let elevation: Double?
    public let timestamp: Date
    public init(latitude: Double, longitude: Double, elevation: Double?, timestamp: Date) {
        self.latitude = latitude; self.longitude = longitude; self.elevation = elevation; self.timestamp = timestamp
    }
    public var isValidGPXPoint: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    public var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

public struct WalkRouteSummary: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date
    public let hasGPSRoute: Bool
    public let title: String?
    /// GPX activity type, e.g. "Walking", "Hiking", "Running".
    public let activity: String?
    public init(id: UUID, startDate: Date, endDate: Date, hasGPSRoute: Bool, title: String? = nil, activity: String? = nil) {
        self.id = id; self.startDate = startDate; self.endDate = endDate
        self.hasGPSRoute = hasGPSRoute; self.title = title; self.activity = activity
    }
    public var durationSeconds: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }
}

public struct WalkSearchFilter: Equatable, Sendable, Codable {
    public var startDate: Date?
    public var endDate: Date?
    public var minimumDuration: TimeInterval?
    public var maximumDuration: TimeInterval?
    public var requiresGPSRoute: Bool?
    public init(startDate: Date? = nil, endDate: Date? = nil, minimumDuration: TimeInterval? = nil, maximumDuration: TimeInterval? = nil, requiresGPSRoute: Bool? = nil) {
        self.startDate = startDate; self.endDate = endDate; self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration; self.requiresGPSRoute = requiresGPSRoute
    }
    public var isActive: Bool { startDate != nil || endDate != nil || minimumDuration != nil || maximumDuration != nil || requiresGPSRoute != nil }
    public func matches(_ s: WalkRouteSummary) -> Bool {
        if let startDate, s.startDate < startDate { return false }
        if let endDate, s.startDate >= endDate { return false }
        if let minimumDuration, s.durationSeconds < minimumDuration { return false }
        if let maximumDuration, s.durationSeconds > maximumDuration { return false }
        if let requiresGPSRoute, s.hasGPSRoute != requiresGPSRoute { return false }
        return true
    }
}

public struct WalkRoutePageCursor: Equatable, Sendable {
    public let startDate: Date; public let id: UUID
    public init(startDate: Date, id: UUID) { self.startDate = startDate; self.id = id }
}

public struct WalkMonth: Identifiable, Hashable, Sendable, Codable {
    public let startDate: Date; public let endDate: Date; public let walkCount: Int
    public init(startDate: Date, endDate: Date, walkCount: Int) { self.startDate = startDate; self.endDate = endDate; self.walkCount = walkCount }
    public var id: Date { startDate }
    public var year: Int { Calendar.current.component(.year, from: startDate) }
    public var monthName: String { startDate.formatted(.dateTime.month(.wide)) }
    public var title: String { startDate.formatted(.dateTime.month(.wide).year()) }
    public static func group(startDates: [Date], calendar: Calendar = .current) -> [WalkMonth] {
        let d = Dictionary(grouping: startDates) { calendar.dateInterval(of: .month, for: $0)?.start }
        return d.compactMap { start, dates in
            guard let start, let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
            return WalkMonth(startDate: start, endDate: interval.end, walkCount: dates.count)
        }.sorted { $0.startDate > $1.startDate }
    }
}

public struct WalkRouteSummaryPage: Sendable { public let summaries: [WalkRouteSummary]; public let nextCursor: WalkRoutePageCursor?; public let hasMore: Bool }

public struct WalkMetadata: Equatable, Sendable {
    public let id: UUID; public let startDate: Date; public let endDate: Date
    public init(id: UUID, startDate: Date, endDate: Date) { self.id = id; self.startDate = startDate; self.endDate = endDate }
}

// MARK: - Places

public struct Place: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var coordinate: CLLocationCoordinate2D
    public var note: String
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, coordinate: CLLocationCoordinate2D, note: String = "", createdAt: Date = .now) {
        self.id = id; self.name = name; self.coordinate = coordinate; self.note = note; self.createdAt = createdAt
    }
    // Codable for coordinate
    enum CodingKeys: String, CodingKey { case id, name, lat, lon, note, createdAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let lat = try c.decode(Double.self, forKey: .lat)
        let lon = try c.decode(Double.self, forKey: .lon)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        note = try c.decode(String.self, forKey: .note)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(coordinate.latitude, forKey: .lat)
        try c.encode(coordinate.longitude, forKey: .lon)
        try c.encode(note, forKey: .note)
        try c.encode(createdAt, forKey: .createdAt)
    }
    public static func == (lhs: Place, rhs: Place) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Flights (stub model)

public struct Flight: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var number: String
    public var origin: String
    public var destination: String
    public var departure: Date
    public var arrival: Date
    /// Imported flights carry their own coordinates; seeded flights fall back to the catalog.
    public var originCoordinate: GeoCoordinate?
    public var destinationCoordinate: GeoCoordinate?
    public init(
        id: UUID = UUID(),
        number: String,
        origin: String,
        destination: String,
        departure: Date,
        arrival: Date,
        originCoordinate: GeoCoordinate? = nil,
        destinationCoordinate: GeoCoordinate? = nil
    ) {
        self.id = id; self.number = number; self.origin = origin; self.destination = destination
        self.departure = departure; self.arrival = arrival
        self.originCoordinate = originCoordinate ?? AirportCatalog.coordinate(for: origin)
        self.destinationCoordinate = destinationCoordinate ?? AirportCatalog.coordinate(for: destination)
    }
    public var durationSeconds: TimeInterval { max(0, arrival.timeIntervalSince(departure)) }
}

// MARK: - Parcels (stub model)

public struct Parcel: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var trackingNumber: String
    public var carrier: String
    public var status: String
    public var lastLocation: CLLocationCoordinate2D?
    public var updatedAt: Date
    public init(id: UUID = UUID(), trackingNumber: String, carrier: String, status: String, lastLocation: CLLocationCoordinate2D? = nil, updatedAt: Date = .now) {
        self.id = id; self.trackingNumber = trackingNumber; self.carrier = carrier; self.status = status
        self.lastLocation = lastLocation; self.updatedAt = updatedAt
    }
    enum CodingKeys: String, CodingKey { case id, trackingNumber, carrier, status, lat, lon, hasLoc, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        trackingNumber = try c.decode(String.self, forKey: .trackingNumber)
        carrier = try c.decode(String.self, forKey: .carrier)
        status = try c.decode(String.self, forKey: .status)
        let hasLoc = try c.decode(Bool.self, forKey: .hasLoc)
        if hasLoc {
            let lat = try c.decode(Double.self, forKey: .lat)
            let lon = try c.decode(Double.self, forKey: .lon)
            lastLocation = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else { lastLocation = nil }
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(trackingNumber, forKey: .trackingNumber)
        try c.encode(carrier, forKey: .carrier)
        try c.encode(status, forKey: .status)
        try c.encode(lastLocation != nil, forKey: .hasLoc)
        if let loc = lastLocation { try c.encode(loc.latitude, forKey: .lat); try c.encode(loc.longitude, forKey: .lon) }
        try c.encode(updatedAt, forKey: .updatedAt)
    }
    public static func == (lhs: Parcel, rhs: Parcel) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - TFL (stub model)

public struct TFLStation: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var coordinate: CLLocationCoordinate2D
    public var lines: [String]
    public init(id: String, name: String, coordinate: CLLocationCoordinate2D, lines: [String] = []) {
        self.id = id; self.name = name; self.coordinate = coordinate; self.lines = lines
    }
    enum CodingKeys: String, CodingKey { case id, name, lat, lon, lines }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let lat = try c.decode(Double.self, forKey: .lat)
        let lon = try c.decode(Double.self, forKey: .lon)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        lines = try c.decode([String].self, forKey: .lines)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(coordinate.latitude, forKey: .lat); try c.encode(coordinate.longitude, forKey: .lon)
        try c.encode(lines, forKey: .lines)
    }
    public static func == (lhs: TFLStation, rhs: TFLStation) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}