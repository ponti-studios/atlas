import Foundation

// MARK: - Model

public struct JamCam: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let coordinate: GeoCoordinate
    public let view: String
    public let imageURL: URL?
    public let videoURL: URL?
    public let isAvailable: Bool

    public init(
        id: String,
        name: String,
        coordinate: GeoCoordinate,
        view: String = "",
        imageURL: URL? = nil,
        videoURL: URL? = nil,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.view = view
        self.imageURL = imageURL
        self.videoURL = videoURL
        self.isAvailable = isAvailable
    }
}

// MARK: - Provider

public protocol JamCamProviding {
    func fetchCameras() async throws -> [JamCam]
}

public enum JamCamError: Error, LocalizedError {
    case badStatus(Int)
    case badPayload

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "TfL returned HTTP \(code)"
        case .badPayload: return "TfL returned an unreadable camera feed"
        }
    }
}

/// Live TfL JamCam feed: `GET https://api.tfl.gov.uk/Place/Type/JamCam`.
/// An app key is optional; set `TFL_APP_KEY` or pass one explicitly.
public struct TFLJamCamClient: JamCamProviding {
    public static let endpoint = URL(string: "https://api.tfl.gov.uk/Place/Type/JamCam")!

    private let session: URLSession
    private let appKey: String?

    public init(session: URLSession? = nil, appKey: String? = nil) {
        self.session = session ?? .shared
        self.appKey = appKey ?? ProcessInfo.processInfo.environment["TFL_APP_KEY"]
    }

    public func fetchCameras() async throws -> [JamCam] {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        if let appKey, !appKey.isEmpty {
            components.queryItems = [URLQueryItem(name: "app_key", value: appKey)]
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("Atlas/1.0 (TfL JamCam viewer)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw JamCamError.badStatus(http.statusCode)
        }
        // 889 places decode in tens of milliseconds; keep that off the main
        // actor so a manual refresh never stalls the camera page.
        return try await Task.detached(priority: .userInitiated) {
            try Self.parse(data)
        }.value
    }

    /// Visible for tests and for the headless CLI.
    public static func parse(_ data: Data) throws -> [JamCam] {
        let places: [Place]
        do {
            places = try JSONDecoder().decode([Place].self, from: data)
        } catch {
            throw JamCamError.badPayload
        }

        return places.compactMap { place -> JamCam? in
            guard !place.commonName.isEmpty,
                  place.lat.isFinite, place.lon.isFinite,
                  (-90...90).contains(place.lat),
                  (-180...180).contains(place.lon) else { return nil }

            let properties = Dictionary(
                place.additionalProperties.map { ($0.key, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            let key = place.id.replacingOccurrences(of: "JamCams_", with: "")
            let fallbackImage = URL(string: "https://s3-eu-west-1.amazonaws.com/jamcams.tfl.gov.uk/\(key).jpg")
            let available = properties["available"]?.lowercased() != "false"

            return JamCam(
                id: place.id,
                name: clean(place.commonName),
                coordinate: GeoCoordinate(latitude: place.lat, longitude: place.lon),
                view: clean(properties["view"] ?? ""),
                imageURL: properties["imageUrl"].flatMap(URL.init(string:)) ?? fallbackImage,
                videoURL: properties["videoUrl"].flatMap(URL.init(string:)),
                isAvailable: available
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Some TfL labels carry a literal backslash before a slash.
    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\\/", with: "/")
    }

    private struct Place: Decodable {
        let id: String
        let commonName: String
        let lat: Double
        let lon: Double
        let additionalProperties: [Property]

        enum CodingKeys: String, CodingKey {
            case id, commonName, lat, lon, additionalProperties
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            commonName = try container.decodeIfPresent(String.self, forKey: .commonName) ?? ""
            lat = try container.decode(Double.self, forKey: .lat)
            lon = try container.decode(Double.self, forKey: .lon)
            additionalProperties = try container.decodeIfPresent([Property].self, forKey: .additionalProperties) ?? []
        }

        struct Property: Decodable {
            let key: String
            let value: String

            enum CodingKeys: String, CodingKey { case key, value }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                key = try container.decode(String.self, forKey: .key)
                if let string = try? container.decode(String.self, forKey: .value) {
                    value = string
                } else if let bool = try? container.decode(Bool.self, forKey: .value) {
                    value = bool ? "true" : "false"
                } else {
                    value = ""
                }
            }
        }
    }
}
