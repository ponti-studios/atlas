import Foundation
import CoreLocation
import MapKit

/// A place found through Apple's own search service. Kept free of `MKMapItem`
/// so the core stays testable and the result survives a round trip through
/// JSON.
public struct PlaceSearchResult: Identifiable, Hashable, Sendable, Codable {
    /// Stable content key. The same place always produces the same id, so
    /// saving it twice updates the place instead of duplicating it.
    public let id: String
    public let name: String
    public let address: String
    public let category: String
    public let latitude: Double
    public let longitude: Double

    public init(id: String, name: String, address: String, category: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.address = address
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(name: String, address: String, category: String, coordinate: CLLocationCoordinate2D) {
        // Round to ~1 cm so two map items for the same door are the same place.
        let lat = (coordinate.latitude * 100_000).rounded() / 100_000
        let lon = (coordinate.longitude * 100_000).rounded() / 100_000
        self.init(
            id: "place|\(name.lowercased())|\(lat)|\(lon)",
            name: name,
            address: address,
            category: category,
            latitude: lat,
            longitude: lon
        )
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The place this result becomes when saved.
    public func makePlace() -> Place {
        Place(
            id: StableID.uuid(id),
            name: name,
            coordinate: coordinate,
            note: [category, address]
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            createdAt: .now
        )
    }
}

/// The seam between the view model and Apple's search service. Tests inject a
/// stub; the app injects MapKit.
public protocol PlaceSearching: Sendable {
    func search(_ query: String, near: GeoCoordinate?, limit: Int) async throws -> [PlaceSearchResult]
}

public enum PlaceSearchError: Error, LocalizedError {
    case emptyQuery
    case noResults

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: return "Type something to search for."
        case .noResults: return "Apple Maps found no matches."
        }
    }
}

/// `MKLocalSearch` — Apple's own local search, no key, no account.
public struct MapKitPlaceSearch: PlaceSearching {
    public init() {}

    public func search(_ query: String, near: GeoCoordinate?, limit: Int = 20) async throws -> [PlaceSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlaceSearchError.emptyQuery }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.address, .pointOfInterest]
        if let near {
            // Bias towards what the user is looking at, but never restrict the
            // search to it.
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude),
                latitudinalMeters: 40_000,
                longitudinalMeters: 40_000
            )
        }

        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(limit).map(Self.result(from:))
    }

    private static func result(from item: MKMapItem) -> PlaceSearchResult {
        let placemark = item.placemark
        let name = item.name ?? placemark.name ?? "Unknown place"
        let address = [placemark.thoroughfare, placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let category = item.pointOfInterestCategory?.rawValue ?? ""
        return PlaceSearchResult(
            name: name,
            address: address,
            category: category,
            coordinate: placemark.coordinate
        )
    }
}
