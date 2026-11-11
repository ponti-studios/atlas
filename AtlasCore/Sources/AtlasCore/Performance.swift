import Foundation
import Darwin
import CoreLocation
import os

// MARK: - Stage timings + counters (app and CLI)

/// Lightweight, always-on stage recorder. Stage marks are cheap (a lock and a
/// dictionary write); repeated samples are only collected when `ATLAS_PERF=1`.
///
/// `os_signpost` intervals are emitted for the same stages, so an Instruments
/// "Points of Interest" track lines up with the numbers reported over Reflex.
public final class AtlasPerformance: @unchecked Sendable {
    public static let shared = AtlasPerformance()

    private let lock = NSLock()
    private let origin = DispatchTime.now().uptimeNanoseconds
    private var stageTimesMS: [String: Double] = [:]
    private var starts: [String: UInt64] = [:]
    private var samplesMS: [String: [Double]] = [:]
    private var counters: [String: Double] = [:]
    private var frameStats: FrameStats?

    private let signposter = OSSignposter(subsystem: "io.ponti.atlas", category: "performance")
    private var signpostIntervals: [String: OSSignpostIntervalState] = [:]

    /// Sampling is opt-in so normal runs do not pay for arrays of timings.
    public private(set) var isSamplingEnabled: Bool = {
        ProcessInfo.processInfo.environment["ATLAS_PERF"] == "1"
    }()

    private init() {}

    public func start() {
        mark("process.start")
    }

    public func enableSampling() {
        lock.lock(); isSamplingEnabled = true; lock.unlock()
    }

    /// Milliseconds since the first `AtlasPerformance` touch.
    public func elapsedMS() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - origin) / 1_000_000
    }

    /// A point-in-time mark (launch, store ready, first map appearance).
    public func mark(_ stage: String) {
        let value = elapsedMS()
        lock.lock()
        stageTimesMS[stage] = value
        signposter.emitEvent("stage")
        lock.unlock()
    }

    public func begin(_ stage: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        starts[stage] = now
        signpostIntervals[stage] = signposter.beginInterval("stage")
        lock.unlock()
    }

    @discardableResult
    public func end(_ stage: String) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        if let state = signpostIntervals.removeValue(forKey: stage) {
            signposter.endInterval("stage", state)
        }
        guard let start = starts.removeValue(forKey: stage) else { return 0 }
        let ms = Double(now - start) / 1_000_000
        stageTimesMS[stage] = ms
        return ms
    }

    /// A measured duration that has already been timed.
    public func record(_ name: String, milliseconds: Double) {
        guard isSamplingEnabled else { return }
        lock.lock()
        samplesMS[name, default: []].append(milliseconds)
        lock.unlock()
    }

    public func increment(_ counter: String, by amount: Double = 1) {
        lock.lock()
        counters[counter, default: 0] += amount
        lock.unlock()
    }

    public func recordFrames(_ stats: FrameStats) {
        lock.lock()
        frameStats = stats
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        stageTimesMS.removeAll()
        starts.removeAll()
        samplesMS.removeAll()
        counters.removeAll()
        frameStats = nil
        lock.unlock()
    }

    public func report() -> PerformanceReport {
        lock.lock()
        defer { lock.unlock() }
        let metrics = samplesMS.map { name, values in
            MetricSummary.make(name: name, samples: values, unit: "ms")
        }.sorted { $0.name < $1.name }
        return PerformanceReport(
            stagesMS: stageTimesMS,
            metrics: metrics,
            counters: counters,
            frames: frameStats,
            footprintBytes: Self.footprintBytes(),
            sampled: isSamplingEnabled
        )
    }

    public func reportJSON() -> String {
        report().jsonString()
    }

    /// Logs the headline startup numbers once the app is interactive.
    public func logSummary() {
        let report = report()
        let decode = report.stagesMS["snapshot.decode"] ?? -1
        let load = report.stagesMS["tabs.load"] ?? -1
        let routes = report.stagesMS["routes.prepare"] ?? -1
        let ready = report.stagesMS["app.ready"] ?? -1
        NSLog(
            "Atlas perf: decode %.0f ms · tabs %.0f ms · routes %.0f ms · ready %.0f ms · footprint %.0f MB",
            decode, load, routes, ready, Double(report.footprintBytes) / 1_048_576
        )
    }

    // MARK: Memory

    public static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint)
    }
}

// MARK: - Report types

public struct MetricSummary: Codable, Sendable {
    public let name: String
    public let unit: String
    public let count: Int
    public let median: Double
    public let p95: Double
    public let min: Double
    public let max: Double
    public let mean: Double

    public static func make(name: String, samples: [Double], unit: String) -> MetricSummary {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else {
            return MetricSummary(name: name, unit: unit, count: 0, median: 0, p95: 0, min: 0, max: 0, mean: 0)
        }
        func percentile(_ p: Double) -> Double {
            let index = Int((Double(sorted.count - 1) * p).rounded())
            return sorted[Swift.min(Swift.max(index, 0), sorted.count - 1)]
        }
        return MetricSummary(
            name: name,
            unit: unit,
            count: sorted.count,
            median: percentile(0.5),
            p95: percentile(0.95),
            min: sorted.first ?? 0,
            max: sorted.last ?? 0,
            mean: sorted.reduce(0, +) / Double(sorted.count)
        )
    }
}

public struct PerformanceReport: Codable, Sendable {
    public let stagesMS: [String: Double]
    public let metrics: [MetricSummary]
    public let counters: [String: Double]
    public let frames: FrameStats?
    public let footprintBytes: Int
    public let sampled: Bool

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct FrameStats: Codable, Sendable {
    public let frames: Int
    public let durationMS: Double
    public let fps: Double
    public let targetMS: Double
    public let p50MS: Double
    public let p95MS: Double
    public let p99MS: Double
    public let maxMS: Double
    public let overBudgetFrames: Int
    public let overBudgetPercent: Double

    public init(intervalsMS: [Double], durationMS: Double, targetMS: Double) {
        self.frames = intervalsMS.count
        self.durationMS = durationMS
        self.fps = durationMS > 0 ? Double(intervalsMS.count) * 1_000 / durationMS : 0
        self.targetMS = targetMS
        let sorted = intervalsMS.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = Swift.min(Swift.max(Int((Double(sorted.count - 1) * p).rounded()), 0), sorted.count - 1)
            return sorted[index]
        }
        self.p50MS = percentile(0.5)
        self.p95MS = percentile(0.95)
        self.p99MS = percentile(0.99)
        self.maxMS = sorted.last ?? 0
        let budget = targetMS * 1.5
        self.overBudgetFrames = intervalsMS.filter { $0 > budget }.count
        self.overBudgetPercent = intervalsMS.isEmpty ? 0 : Double(overBudgetFrames) * 100 / Double(intervalsMS.count)
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Headless benchmark

public struct BenchmarkReport: Codable, Sendable {
    public let label: String
    public let generatedAt: Date
    public let snapshotPath: String
    public let snapshotBytes: Int
    public let walks: Int
    public let routes: Int
    public let points: Int
    public let places: Int
    public let flights: Int
    public let footprintBytes: Int
    public let metrics: [MetricSummary]

    public func metric(_ name: String) -> MetricSummary? {
        metrics.first { $0.name == name }
    }

    public func text() -> String {
        func pad(_ value: String, _ width: Int) -> String {
            value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
        }
        func number(_ value: Double) -> String { String(format: "%9.2f", value) }

        var lines: [String] = []
        lines.append("Atlas benchmark · \(label) · \(walks) walks / \(points) points / \(places) places / \(flights) flights")
        lines.append("snapshot \(String(format: "%.1f", Double(snapshotBytes) / 1_048_576)) MB · footprint \(String(format: "%.0f", Double(footprintBytes) / 1_048_576)) MB")
        lines.append("")
        lines.append(pad("metric", 30) + pad("n", 5) + pad("median", 11) + pad("p95", 11) + pad("min", 11) + pad("max", 11) + "unit")
        for metric in metrics {
            lines.append(
                pad(metric.name, 30)
                + pad("\(metric.count)", 5)
                + number(metric.median)
                + number(metric.p95)
                + number(metric.min)
                + number(metric.max)
                + " " + metric.unit
            )
        }
        return lines.joined(separator: "\n")
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(from data: Data) throws -> BenchmarkReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BenchmarkReport.self, from: data)
    }
}

public enum AtlasBenchmark {
    /// Runs the same workloads the app performs on the real snapshot. Every
    /// metric is a full, independent execution of that stage.
    @MainActor
    public static func run(
        snapshotURL: URL,
        iterations: Int = 5,
        label: String = "current"
    ) async throws -> BenchmarkReport {
        AtlasPerformance.shared.start()
        let payload = try Data(contentsOf: snapshotURL)
        let decoded = try JSONDecoder().decode(AtlasData.self, from: payload)
        let routesByID = Dictionary(decoded.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var metrics: [MetricSummary] = []
        func record(_ name: String, _ samples: [Double]) {
            metrics.append(MetricSummary.make(name: name, samples: samples, unit: "ms"))
        }
        func time(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        func timeAsync(_ body: () async -> Void) async -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            await body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        func series(_ count: Int, _ body: () -> Void) -> [Double] {
            var samples: [Double] = []
            samples.reserveCapacity(count)
            for _ in 0..<count { samples.append(time(body)) }
            return samples
        }

        // Snapshot read + decode.
        record("snapshot.read", series(iterations) { AtlasBenchmark.consume(try! Data(contentsOf: snapshotURL).count) })
        record("snapshot.decode", series(iterations) { AtlasBenchmark.consume((try! JSONDecoder().decode(AtlasData.self, from: payload)).walks.count) })
        record("snapshot.load", series(iterations) { AtlasBenchmark.consume(try! JSONDecoder().decode(AtlasData.self, from: Data(contentsOf: snapshotURL)).walks.count) })
        record("snapshot.encode", series(max(2, iterations / 2)) { AtlasBenchmark.consume((try! JSONEncoder().encode(decoded)).count) })

        // Route index.
        record("store.index", series(iterations) {
            let index = Dictionary(decoded.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            AtlasBenchmark.consume(index.count)
        })

        // Whole-view-model load against a ready store (decode excluded).
        let warmStore = FileAtlasStore(url: snapshotURL)
        await warmStore.waitUntilReady()
        var hotSamples: [Double] = []
        for _ in 0..<iterations {
            hotSamples.append(await timeAsync {
                let tabs = AtlasTabs(store: warmStore)
                await tabs.load()
                AtlasBenchmark.consume(tabs.walks.walks.count + tabs.places.places.count)
            })
        }
        record("tabs.load.hot", hotSamples)

        // Real cold path: decode + load.
        var coldSamples: [Double] = []
        for _ in 0..<max(2, iterations / 2) {
            coldSamples.append(await timeAsync {
                let store = FileAtlasStore(url: snapshotURL)
                let tabs = AtlasTabs(store: store)
                await tabs.load()
                AtlasBenchmark.consume(tabs.walks.walks.count)
            })
        }
        record("tabs.load.cold", coldSamples)

        // Walk metadata.
        record("walks.months", series(iterations) { AtlasBenchmark.consume(WalkMonth.group(startDates: decoded.walks.map(\.startDate)).count) })
        record("walks.page", series(max(iterations, 10)) {
            let list = decoded.walks.sorted { $0.startDate > $1.startDate }
            AtlasBenchmark.consume(Array(list.prefix(100)).count)
        })

        let city = GeoRegion(center: GeoCoordinate(latitude: 51.5074, longitude: -0.1278), latitudeDelta: 0.05, longitudeDelta: 0.07)
        let metro = GeoRegion(center: GeoCoordinate(latitude: 51.5074, longitude: -0.1278), latitudeDelta: 0.5, longitudeDelta: 0.65)
        let world = GeoRegion(center: GeoCoordinate(latitude: 25, longitude: -20), latitudeDelta: 20, longitudeDelta: 30)

        // The route preparation `ContentView.loadRoutes` now performs: filter
        // valid points, compute a bounding box, build the overview LOD, and walk
        // every segment once for the distance.
        record("routes.prepare", series(max(iterations, 10)) {
            var overlayCount = 0
            var distanceSink = 0.0
            for walk in decoded.walks where walk.hasGPSRoute {
                guard let route = routesByID[walk.id] else { continue }
                let points = route.locations.filter(\.isValidGPXPoint).map { GeoCoordinate($0.coordinate) }
                guard points.count > 1 else { continue }
                let simplified = RouteGeometry.simplify(points, toleranceMeters: 9, maxPoints: 420)
                overlayCount += simplified.count
                distanceSink += RouteGeometry.length(points)
            }
            AtlasBenchmark.consume(overlayCount)
            AtlasBenchmark.consume(distanceSink > 0 ? 1 : 0)
        })

        record("routes.simplify", series(max(iterations, 10)) {
            var sink = 0
            for route in decoded.routes {
                let points = route.locations.map { GeoCoordinate($0.coordinate) }
                sink += RouteGeometry.simplify(points, toleranceMeters: 9, maxPoints: 420).count
            }
            AtlasBenchmark.consume(sink)
        })

        // Render culling: rank places in local degree space with one cosine,
        // rather than running haversine for all 1,550.
        for (name, region) in [("city", city), ("metro", metro), ("world", world)] {
            record("places.cull.\(name)", series(max(iterations, 20)) {
                let limit = region.latitudeDelta > 4 ? 40 : (region.latitudeDelta > 0.8 ? 90 : 200)
                let cosLatitude = cos(region.center.latitude * .pi / 180)
                let nearest = decoded.places
                    .map { place -> (Place, Double) in
                        let dLat = place.coordinate.latitude - region.center.latitude
                        let dLon = (place.coordinate.longitude - region.center.longitude) * cosLatitude
                        return (place, dLat * dLat + dLon * dLon)
                    }
                    .sorted { $0.1 < $1.1 }
                    .prefix(limit)
                    .map(\.0)
                AtlasBenchmark.consume(nearest.count)
            })
        }

        // Current flightArcs: great-circle path, midpoint, bearing per leg.
        record("flights.arcs", series(max(iterations, 20)) {
            var sink = 0
            for flight in decoded.flights {
                guard let origin = flight.originCoordinate, let destination = flight.destinationCoordinate else { continue }
                let path = origin.greatCircle(to: destination, steps: 72)
                _ = path[safe: path.count / 2]
                sink += path.count
                AtlasBenchmark.consume(Int(origin.bearing(to: destination)))
            }
            AtlasBenchmark.consume(sink)
        })

        // Camera fit for the newest route.
        if let newest = decoded.walks.first, let route = routesByID[newest.id] {
            let points = route.locations.map { GeoCoordinate($0.coordinate) }
            record("camera.fit.route", series(max(iterations, 20)) {
                AtlasBenchmark.consume(GeoRegion.fitting(points, padding: 1.7)?.latitudeDelta ?? 0)
            })
        }

        // Card construction currently runs inside `body`; string formatting is
        // the cost, so measure the real formatter calls.
        record("cards.walks", series(max(iterations, 10)) {
            var sink = 0
            for walk in decoded.walks {
                let time = walk.startDate.formatted(date: .omitted, time: .shortened)
                let day = walk.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                sink += time.count + day.count
            }
            AtlasBenchmark.consume(sink)
        })
        record("cards.places", series(max(iterations, 10)) {
            var sink = 0
            for place in decoded.places {
                sink += String(format: "%.3f, %.3f", place.coordinate.latitude, place.coordinate.longitude).count
            }
            AtlasBenchmark.consume(sink)
        })
        record("cards.flights", series(max(iterations, 20)) {
            var sink = 0
            for flight in decoded.flights {
                sink += flight.departure.formatted(.dateTime.day().month(.abbreviated).hour().minute()).count
            }
            AtlasBenchmark.consume(sink)
        })

        return BenchmarkReport(
            label: label,
            generatedAt: Date(),
            snapshotPath: snapshotURL.path,
            snapshotBytes: payload.count,
            walks: decoded.walks.count,
            routes: decoded.routes.count,
            points: decoded.pointCount,
            places: decoded.places.count,
            flights: decoded.flights.count,
            footprintBytes: AtlasPerformance.footprintBytes(),
            metrics: metrics
        )
    }

    /// Prints a before/after table. Lower is better for every metric we track.
    public static func compare(baseline: BenchmarkReport, current: BenchmarkReport) -> String {
        func pad(_ value: String, _ width: Int) -> String {
            value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
        }
        var lines: [String] = []
        lines.append("Atlas benchmark delta · \(baseline.label) -> \(current.label)")
        lines.append("")
        lines.append(pad("metric", 30) + pad("baseline", 12) + pad("current", 12) + pad("delta", 10) + "verdict")
        for metric in baseline.metrics {
            guard let now = current.metric(metric.name) else { continue }
            let delta = metric.median > 0 ? (now.median - metric.median) / metric.median * 100 : 0
            let verdict: String
            if abs(delta) < 2 { verdict = "same" }
            else if delta < 0 { verdict = String(format: "%.0f%% faster", -delta) }
            else { verdict = String(format: "%.0f%% slower", delta) }
            lines.append(
                pad(metric.name, 30)
                + pad(String(format: "%.2f ms", metric.median), 12)
                + pad(String(format: "%.2f ms", now.median), 12)
                + pad(String(format: "%+.1f%%", delta), 10)
                + verdict
            )
        }
        let before = Double(baseline.footprintBytes) / 1_048_576
        let after = Double(current.footprintBytes) / 1_048_576
        lines.append("")
        lines.append(String(format: "footprint  %.0f MB -> %.0f MB (%+.0f%%)", before, after, before > 0 ? (after - before) / before * 100 : 0))
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    @inline(never)
    private static func consume(_ value: Int) {
        if value == Int.min { print(value) }
    }

    @inline(never)
    private static func consume(_ value: Double) {
        if value == -Double.infinity { print(value) }
    }

    static func length(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count > 1 else { return 0 }
        var total = 0.0
        var previous = GeoCoordinate(coordinates[0])
        for coordinate in coordinates.dropFirst() {
            let next = GeoCoordinate(coordinate)
            total += previous.distance(to: next)
            previous = next
        }
        return total
    }
}

// MARK: - Small helpers

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}


