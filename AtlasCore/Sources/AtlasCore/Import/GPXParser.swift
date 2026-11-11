import Foundation

/// A parsed GPX track. Timestamps stay optional here; the importer decides how
/// to fill gaps so a malformed file never produces a fake route.
public struct GPXSample: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let elevation: Double?
    public let timestamp: Date?
}

public struct GPXDocument: Sendable {
    public let name: String?
    public let activity: String?
    public let samples: [GPXSample]
}

enum GPXParser {
    static func parse(data: Data) -> GPXDocument? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let samples = delegate.samples.filter {
            let coordinate = GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude)
            return coordinate.isValid
        }
        guard !samples.isEmpty else { return nil }
        return GPXDocument(name: delegate.trackName, activity: delegate.activity, samples: samples)
    }

    static func parse(contentsOf url: URL) -> GPXDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var samples: [GPXSample] = []
        var trackName: String?
        var activity: String?

        private var current: (latitude: Double, longitude: Double)?
        private var currentElevation: Double?
        private var currentTimestamp: Date?
        private var text = ""
        private var collectingName = false
        private var collectingActivity = false

        private static let iso: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        private static let isoFractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "trkpt":
                if let latitude = Double(attributeDict["lat"] ?? ""),
                   let longitude = Double(attributeDict["lon"] ?? "") {
                    current = (latitude, longitude)
                    currentElevation = nil
                    currentTimestamp = nil
                }
            case "name":
                collectingName = trackName == nil
                text = ""
            case "type":
                collectingActivity = activity == nil
                text = ""
            case "ele":
                text = ""
            case "time":
                text = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "trkpt":
                if let current {
                    samples.append(GPXSample(
                        latitude: current.latitude,
                        longitude: current.longitude,
                        elevation: currentElevation,
                        timestamp: currentTimestamp
                    ))
                }
                current = nil
            case "name":
                if collectingName {
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { trackName = value }
                    collectingName = false
                }
            case "type":
                if collectingActivity {
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { activity = value }
                    collectingActivity = false
                }
            case "ele":
                currentElevation = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "time":
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                currentTimestamp = Self.isoFractional.date(from: value) ?? Self.iso.date(from: value)
            default:
                break
            }
            text = ""
        }
    }
}
