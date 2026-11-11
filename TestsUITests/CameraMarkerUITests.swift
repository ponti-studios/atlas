import XCTest

/// Taps a street-level camera dot on the live map and expects the monitor to
/// open. The viewport is positioned through the app's Reflex socket, so the
/// dot under the tap is known exactly: locating a camera centres it, which
/// puts it under the middle of the map. A synthetic tap is the only way to
/// exercise SwiftUI gesture delivery without a finger.
final class CameraMarkerUITests: XCTestCase {
    private let cameraID = "JamCams_00001.03507"

    func testTappingCameraDotOpensTheMonitor() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ATLAS_REFLEX"] = "1"
        app.launch()

        try Reflex.waitUntilListening()
        _ = try Reflex.send("tab 5")
        try locateCamera()

        let map = app.descendants(matching: .any)["atlas.map"].firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10), "the map exposes no element to tap")

        let close = app.buttons["Close camera"]
        XCTAssertTrue(
            close.waitForExistence(timeout: 20),
            "locating \(cameraID) did not open its monitor"
        )

        // Dismiss through Reflex so the tap is tested from a clean state
        // regardless of how the card's own close control behaves.
        _ = try Reflex.send("camera clear")
        XCTAssertNil(try selectedCamera(), "clearing the selection failed")

        let before = try regionCenter()
        let centre = map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        #if os(macOS)
        centre.click()
        #else
        centre.tap()
        #endif

        XCTAssertEqual(try selectedCamera(), cameraID, "tapping the centred dot did not select it")
        XCTAssertTrue(
            close.waitForExistence(timeout: 5),
            "tapping the centred camera dot did not open its monitor"
        )

        // Selecting from the map must not move the camera.
        let after = try regionCenter()
        XCTAssertEqual(after.latitude, before.latitude, accuracy: 0.0005)
        XCTAssertEqual(after.longitude, before.longitude, accuracy: 0.0005)
    }

    private func selectedCamera() throws -> String? {
        let response = try Reflex.send("camera status")
        let object = try JSONSerialization.jsonObject(with: Data(response.utf8))
        return (object as? [String: Any])?["selected"] as? String
    }

    /// A control for the tap test: the card's own close control must clear the
    /// selection, otherwise a failed dismissal would be misread as a tap hit.
    func testClosingTheMonitorClearsTheSelection() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ATLAS_REFLEX"] = "1"
        app.launch()

        try Reflex.waitUntilListening()
        _ = try Reflex.send("tab 5")
        try locateCamera()

        let close = app.buttons["Close camera"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "the monitor did not open")
        XCTAssertEqual(try selectedCamera(), cameraID)

        #if os(macOS)
        close.click()
        #else
        close.tap()
        #endif
        XCTAssertNil(try selectedCamera(), "closing the monitor kept the camera selected")
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "the monitor stayed on screen")
    }

    /// Cameras arrive from TfL asynchronously, so wait for the feed before
    /// asking for one by id.
    private func locateCamera() throws {
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            let response = try Reflex.send("camera \(cameraID)")
            if response.contains(cameraID) {
                _ = try Reflex.send("camera locate")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("the TfL camera feed never loaded \(cameraID)")
    }

    private func regionCenter() throws -> (latitude: Double, longitude: Double) {
        let response = try Reflex.send("map")
        let object = try JSONSerialization.jsonObject(with: Data(response.utf8))
        guard
            let root = object as? [String: Any],
            let state = root["state"] as? [String: Any],
            let region = state["region"] as? [String: Any],
            let center = region["center"] as? [String: Any],
            let latitude = center["latitude"] as? Double,
            let longitude = center["longitude"] as? Double
        else {
            throw Reflex.Failure.unreadable(response)
        }
        return (latitude, longitude)
    }
}

/// One command per connection, matching the app's line protocol. Blocking
/// sockets keep the test free of concurrency ceremony: every command is a
/// round trip of a few milliseconds.
private enum Reflex {
    enum Failure: Error {
        case unreachable
        case socket(String)
        case unreadable(String)
    }

    static func waitUntilListening(timeout: TimeInterval = 40) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? send("ls")) != nil { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw Failure.unreachable
    }

    static func send(_ command: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket: \(errno)") }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(18765).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw Failure.socket("connect: \(errno)") }

        let request = Array((command + "\n").utf8)
        guard write(fd, request, request.count) == request.count else {
            throw Failure.socket("write: \(errno)")
        }

        var response = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            response.append(contentsOf: chunk[0..<count])
            if chunk[0..<count].contains(0x0A) { break }
        }
        guard !response.isEmpty else { throw Failure.socket("read: empty response") }
        return String(decoding: response, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
