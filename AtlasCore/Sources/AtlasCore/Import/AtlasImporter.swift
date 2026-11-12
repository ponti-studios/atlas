import Foundation
import CoreLocation
import CryptoKit

public struct AtlasImportReport: Sendable {
    public let walks: Int
    public let routes: Int
    public let points: Int
    public let places: Int
    public let flights: Int
    public let skippedPlaces: Int
    public let duplicatePlaces: Int
    public let skippedFlights: Int
    public let duration: TimeInterval

    public var text: String {
        String(
            format: "imported %d walks (%d routes, %d points), %d places, %d flights in %.2fs · skipped %d places, %d duplicates, %d flights",
            walks, routes, points, places, flights, duration, skippedPlaces, duplicatePlaces, skippedFlights
        )
    }
}

/// Turns a folder of GPX tracks and the personal-data CSV exports into one
/// portable `AtlasData` snapshot.
public enum AtlasImporter {
    public static func build(
        gpxDirectory: URL,
        placesCSV: URL? = nil,
        transportCSV: URL? = nil,
        airportsCSV: URL? = nil
    ) throws -> (data: AtlasData, report: AtlasImportReport) {
        let started = Date()
        var airports = AirportCatalog.all
        var places: [Place] = []
        var skippedPlaces = 0
        var duplicatePlaces = 0
        var flights: [Flight] = []
        var skippedFlights = 0

        if let airportsCSV, let text = try? String(contentsOf: airportsCSV, encoding: .utf8) {
            for row in CSVTable(text: text).rows {
                guard let code = row["code"]?.uppercased(), !code.isEmpty,
                      let coordinate = CSVValue.coordinate(latitude: row["latitude"], longitude: row["longitude"]) else { continue }
                airports[code] = coordinate
            }
        }

        if let placesCSV, let text = try? String(contentsOf: placesCSV, encoding: .utf8) {
            for row in CSVTable(text: text).rows {
                let name = normalizedPlaceName(row["name"] ?? "")
                guard !name.isEmpty,
                      let coordinate = CSVValue.coordinate(latitude: row["latitude"], longitude: row["longitude"]) else {
                    skippedPlaces += 1
                    continue
                }
                let address = (row["formatted_address"] ?? "").replacingOccurrences(of: "\n", with: ", ")
                let fallback = [row["city"], row["country"]]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                let note = address.isEmpty ? fallback : address
                let id = UUID(uuidString: row["id"] ?? "") ?? stableID("place|\(name)|\(coordinate.latitude)|\(coordinate.longitude)")
                places.append(Place(
                    id: id,
                    name: name,
                    coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    note: note,
                    createdAt: parseTimestamp(row["createdat"]) ?? .distantPast
                ))
            }
        }

        if let transportCSV, let text = try? String(contentsOf: transportCSV, encoding: .utf8) {
            for row in CSVTable(text: text).rows {
                guard (row["mode"] ?? "").lowercased() == "air" else { continue }
                let origin = (row["origin"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let destination = (row["destination"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard let from = airports[origin], let to = airports[destination],
                      let date = parseDateOnly(row["date"]) else {
                    skippedFlights += 1
                    continue
                }
                let departure = date.addingTimeInterval(9 * 3_600)
                let hours = from.distance(to: to) / 850_000 + 0.75
                let arrival = departure.addingTimeInterval(max(45 * 60, hours * 3_600))
                let number = (row["number"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                flights.append(Flight(
                    id: stableID("flight|\(origin)|\(destination)|\(row["date"] ?? "")|\(number)"),
                    number: number.isEmpty ? "\(origin)–\(destination)" : number,
                    origin: origin,
                    destination: destination,
                    departure: departure,
                    arrival: arrival,
                    originCoordinate: from,
                    destinationCoordinate: to
                ))
            }
        }

        // Walks: newest first so the first card is the most recent route.
        // The scan is recursive: an Apple Health export keeps its routes in
        // `apple_health_export/workout-routes/`, one folder below the root.
        let gpxFiles = gpxFiles(in: gpxDirectory)

        var walks: [WalkRouteSummary] = []
        var routes: [WalkRoute] = []
        var points = 0

        for file in gpxFiles {
            guard let document = GPXParser.parse(contentsOf: file), document.samples.count > 0 else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let fallback = parseLeadingDate(name) ?? .distantPast

            let locations = document.samples.enumerated().map { index, sample in
                RouteLocation(
                    latitude: sample.latitude,
                    longitude: sample.longitude,
                    elevation: sample.elevation,
                    timestamp: sample.timestamp ?? fallback.addingTimeInterval(Double(index))
                )
            }
            guard let first = locations.first, let last = locations.last else { continue }
            let start = min(first.timestamp, last.timestamp)
            let end = max(first.timestamp, last.timestamp)

            let activity = document.activity?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawName = document.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Exports name tracks "Walking - 2024-01-01"; keep only genuinely
            // custom names, and let the UI compose a human title from activity + time.
            let generatedName = activity.map { prefix in rawName?.hasPrefix("\(prefix) - ") == true } ?? false
            let title = (rawName?.isEmpty == false && !generatedName) ? rawName : nil
            let id = stableID("walk|\(file.lastPathComponent)")
            let hasRoute = locations.count > 1

            // Geometry facts travel with the summary, so the app never has to
            // scan every route to know where it is. A track with no drawable
            // route is not imported at all.
            let coordinates = locations.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            guard hasRoute, let bounds = GeoBounds(points: coordinates) else { continue }
            let distance = RouteGeometry.length(coordinates)

            walks.append(WalkRouteSummary(
                id: id,
                startDate: start,
                endDate: end,
                hasGPSRoute: true,
                title: title,
                activity: activity,
                bounds: bounds,
                pointCount: locations.count,
                distanceMeters: distance
            ))
            routes.append(WalkRoute(id: id, startDate: start, endDate: end, locations: locations))
            points += locations.count
        }

        // The export can contain the same place several times (different
        // provider ids, names with embedded addresses). Collapse identical
        // names at the same coordinate so the card list has one entry per place.
        var seenPlaces = Set<String>()
        let placesBeforeDedupe = places.count
        places = places.filter { place in
            let key = "\(place.name.lowercased())|\(Int((place.coordinate.latitude * 100_000).rounded()))|\(Int((place.coordinate.longitude * 100_000).rounded()))"
            return seenPlaces.insert(key).inserted
        }
        duplicatePlaces = placesBeforeDedupe - places.count

        walks.sort { $0.startDate > $1.startDate }
        flights.sort { $0.departure < $1.departure }

        let data = AtlasData(
            walks: walks,
            routes: routes,
            places: places,
            flights: flights,
            parcels: [],
            stations: Self.londonStations
        )
        let report = AtlasImportReport(
            walks: walks.count,
            routes: routes.count,
            points: points,
            places: places.count,
            flights: flights.count,
            skippedPlaces: skippedPlaces,
            duplicatePlaces: duplicatePlaces,
            skippedFlights: skippedFlights,
            duration: Date().timeIntervalSince(started)
        )
        return (data, report)
    }

    public static func write(_ data: AtlasData, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        let payload = try encoder.encode(data)
        try payload.write(to: url, options: [.atomic])
    }

    // MARK: - Parsing helpers

    /// Every `.gpx` beneath `directory`, newest name first. Recursive because a
    /// Health export nests its routes, and a personal GPX folder may be nested
    /// by year.
    static func gpxFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "gpx" {
            found.append(url)
        }
        return found.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Personal-data exports sometimes encode line breaks and commas as literal
    /// `\n` / `\,` inside a name. Keep the first line (the venue) and unescape
    /// the comma; the full address already lives in `note`.
    static func normalizedPlaceName(_ raw: String) -> String {
        var name = raw
        name = name.replacingOccurrences(of: "\\r\\n", with: "\n")
        name = name.replacingOccurrences(of: "\\n", with: "\n")
        name = name.replacingOccurrences(of: "\r", with: "\n")
        if let firstLine = name.split(separator: "\n", omittingEmptySubsequences: true).first {
            name = String(firstLine)
        }
        name = name.replacingOccurrences(of: "\\,", with: ",")
        // Some rows append the address after a comma while the note already
        // carries it. The venue is the part before the first comma.
        if let comma = name.firstIndex(of: ",") {
            let venue = name[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
            if venue.count >= 3 { name = venue }
        }
        // Drop a trailing parenthetical address, e.g. "Cafe (123 Main St".
        if let paren = name.range(of: " (") {
            let venue = name[..<paren.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if venue.count >= 3 { name = venue }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        return name
    }

    private static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let timestampFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func parseDateOnly(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return dateOnly.date(from: String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10)))
    }

    static func parseLeadingDate(_ raw: String) -> Date? {
        parseDateOnly(String(raw.prefix(10)))
    }

    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let prefix = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(19))
        return timestampFormat.date(from: prefix)
    }

    /// Stable across imports so selections and links survive a rebuild.
    static func stableID(_ seed: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static let londonStations: [TFLStation] = [
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
