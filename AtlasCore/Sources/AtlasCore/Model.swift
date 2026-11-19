import Foundation
import CoreLocation

public struct Place: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var coordinate: CLLocationCoordinate2D
    public var note: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        coordinate: CLLocationCoordinate2D,
        note: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.note = note
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case lat
        case lon
        case note
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let lat = try container.decode(Double.self, forKey: .lat)
        let lon = try container.decode(Double.self, forKey: .lon)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        note = try container.decode(String.self, forKey: .note)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(coordinate.latitude, forKey: .lat)
        try container.encode(coordinate.longitude, forKey: .lon)
        try container.encode(note, forKey: .note)
        try container.encode(createdAt, forKey: .createdAt)
    }

    public static func == (lhs: Place, rhs: Place) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
