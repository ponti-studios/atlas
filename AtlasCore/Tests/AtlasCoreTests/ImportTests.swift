import XCTest
@testable import AtlasCore

final class ImportTests: XCTestCase {
    func testCSVHandlesCRLFQuotesAndEmbeddedCommas() {
        let text = "id,name,note\r\n1,\"Bell Street, Fitzroy\",\"line one\r\nline two\"\r\n2,Plain,ok\r\n"
        let table = CSVTable(text: text)
        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table.rows[0]["name"], "Bell Street, Fitzroy")
        XCTAssertEqual(table.rows[0]["note"], "line one\r\nline two")
        XCTAssertEqual(table.rows[1]["name"], "Plain")
    }

    func testGPXParserReadsTrackNamePointsAndTimes() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1">
          <trk>
            <name>Hiking - 2021-09-25</name>
            <type>Hiking</type>
            <trkseg>
              <trkpt lat="34.1" lon="-118.1"><ele>100.5</ele><time>2021-09-25T18:00:00+02:00</time></trkpt>
              <trkpt lat="34.2" lon="-118.2"><ele>110</ele><time>2021-09-25T18:00:10+02:00</time></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
        let document = GPXParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(document?.name, "Hiking - 2021-09-25")
        XCTAssertEqual(document?.activity, "Hiking")
        XCTAssertEqual(document?.samples.count, 2)
        XCTAssertEqual(document?.samples.first?.elevation, 100.5)
        XCTAssertNotNil(document?.samples.first?.timestamp)
    }

    @MainActor
    func testImporterBuildsASnapshotFromRealShapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gpxA = """
        <?xml version="1.0"?><gpx><trk><name>Morning loop</name><trkseg>
        <trkpt lat="51.500" lon="-0.120"><time>2024-01-01T08:00:00Z</time></trkpt>
        <trkpt lat="51.501" lon="-0.121"><time>2024-01-01T08:10:00Z</time></trkpt>
        <trkpt lat="51.502" lon="-0.122"><time>2024-01-01T08:20:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        let gpxB = """
        <?xml version="1.0"?><gpx><trk><name>Second loop</name><trkseg>
        <trkpt lat="51.510" lon="-0.130"><time>2024-02-01T08:00:00Z</time></trkpt>
        <trkpt lat="51.511" lon="-0.131"><time>2024-02-01T08:30:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """
        try gpxA.write(to: root.appendingPathComponent("2024-01-01_walking.gpx"), atomically: true, encoding: .utf8)
        try gpxB.write(to: root.appendingPathComponent("2024-02-01_walking.gpx"), atomically: true, encoding: .utf8)

        let places = """
        id,name,formatted_address,city,country,latitude,longitude,createdat
        ,Home,1 Test Street,London,GB,51.5,-0.12,2026-08-05 17:11:53.364817+00
        ,Broken,,,,-999,0,2026-08-05 17:11:53
        ,Far Away,,Sydney,AU,-33.86,151.20,2026-08-05 17:11:53
        ,Alamo Drafthouse Cinema\\n700 W 7th St,,Los Angeles,US,34.05,-118.25,2026-08-05 17:11:53
        ,Alamo Drafthouse Cinema\\n700 W 7th St,,Los Angeles,US,34.05,-118.25,2026-08-05 17:11:53
        ,"Alamo Drafthouse Cinema, Los Angeles",,Los Angeles,US,34.05,-118.25,2026-08-05 17:11:53
        """
        try places.write(to: root.appendingPathComponent("places.csv"), atomically: true, encoding: .utf8)

        let transport = """
        transport_id,date,mode,origin,destination,carrier,number\r
        T-1,2024-03-01,air,AAA,BBB,"Qantas; Delta codeshare",QF1\r
        T-2,2024-03-02,rail,AAA,BBB,Amtrak,99\r
        """
        try transport.write(to: root.appendingPathComponent("transport.csv"), atomically: true, encoding: .utf8)

        let airports = """
        code,name,latitude,longitude
        AAA,Alpha,51.0,-0.5
        BBB,Bravo,52.0,-1.0
        """
        try airports.write(to: root.appendingPathComponent("airports.csv"), atomically: true, encoding: .utf8)

        let (data, report) = try AtlasImporter.build(
            gpxDirectory: root,
            placesCSV: root.appendingPathComponent("places.csv"),
            transportCSV: root.appendingPathComponent("transport.csv"),
            airportsCSV: root.appendingPathComponent("airports.csv")
        )

        XCTAssertEqual(data.walks.count, 2)
        XCTAssertEqual(data.routes.count, 2)
        XCTAssertEqual(report.walks, 2)
        XCTAssertEqual(data.walks.first?.title, "Second loop") // newest first
        XCTAssertEqual(data.places.count, 3)
        XCTAssertEqual(data.places.first(where: { $0.name.hasPrefix("Alamo") })?.name, "Alamo Drafthouse Cinema")
        XCTAssertEqual(data.flights.count, 1)
        XCTAssertEqual(data.flights.first?.originCoordinate?.latitude ?? 0, 51.0, accuracy: 0.001)
        XCTAssertGreaterThan(data.flights.first?.arrival ?? .distantPast, data.flights.first?.departure ?? .distantFuture)
        XCTAssertEqual(report.skippedPlaces, 1)
        XCTAssertEqual(report.duplicatePlaces, 2)
        XCTAssertEqual(report.skippedFlights, 0)
    }

    func testWalkRoutePersistsCompactCoordinatesAndStaysReadable() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let route = WalkRoute(
            id: UUID(),
            startDate: start,
            endDate: start.addingTimeInterval(20),
            locations: [
                RouteLocation(latitude: 51.500, longitude: -0.120, elevation: 10, timestamp: start),
                RouteLocation(latitude: 51.501, longitude: -0.121, elevation: 11, timestamp: start.addingTimeInterval(10)),
                RouteLocation(latitude: 51.502, longitude: -0.122, elevation: 12, timestamp: start.addingTimeInterval(20)),
            ]
        )

        let data = try JSONEncoder().encode(route)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("\"locations\""), "new snapshots should not persist per-point objects")
        XCTAssertTrue(json.contains("\"coordinates\""))

        let decoded = try JSONDecoder().decode(WalkRoute.self, from: data)
        XCTAssertEqual(decoded.locations.count, 3)
        XCTAssertEqual(decoded.locations[1].latitude, 51.501, accuracy: 0.00001)
        XCTAssertEqual(decoded.locations[1].longitude, -0.121, accuracy: 0.00001)
        XCTAssertEqual(decoded.locations.last?.timestamp, route.endDate)
        XCTAssertNil(decoded.locations[1].elevation)
    }

    func testWalkRouteStillDecodesLegacyLocationsArray() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","startDate":\(start.timeIntervalSinceReferenceDate),"endDate":\(start.addingTimeInterval(5).timeIntervalSinceReferenceDate),"locations":[{"latitude":1,"longitude":2,"timestamp":\(start.timeIntervalSinceReferenceDate)},{"latitude":3,"longitude":4,"timestamp":\(start.addingTimeInterval(5).timeIntervalSinceReferenceDate)}]}
        """
        let route = try JSONDecoder().decode(WalkRoute.self, from: Data(legacy.utf8))
        XCTAssertEqual(route.locations.count, 2)
        XCTAssertEqual(route.locations.first?.latitude, 1)
    }

}
