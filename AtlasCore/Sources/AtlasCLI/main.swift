import Foundation
import AtlasCore

@main
@MainActor
struct AtlasCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == "import" {
            runImport(Array(arguments.dropFirst()))
            return
        }

        if arguments.first == "bench" {
            await runBench(Array(arguments.dropFirst()))
            return
        }

        let store = AtlasStoreFactory.make()
        await store.waitUntilReady()
        let (tree, tabs) = makeAtlasTree(store: store)
        await tabs.load()

        if arguments.first == "stats" {
            printStats(tabs)
            return
        }

        if arguments.first == "cams" {
            await runCams(tabs, arguments: Array(arguments.dropFirst()))
            return
        }

        if arguments.first == "perf" {
            print(AtlasPerformance.shared.reportJSON())
            return
        }

        if arguments.isEmpty {
            let source = AtlasDataLocation.existingDataFile()?.path ?? "seeded demo data"
            print("atlas-cli (Reflex) · \(source)")
            print("Commands: ls | do <Action> [json] | tab <0-5> | map | stats | cams [limit]")
            while let line = readLine() {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                await handle(t, tree: tree, tabs: tabs)
            }
        } else {
            await handle(arguments.joined(separator: " "), tree: tree, tabs: tabs)
        }
    }

    // MARK: - Commands

    @MainActor
    static func handle(_ cmd: String, tree: IntrospectionTree, tabs: AtlasTabs) async {
        let parts = cmd.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let verb = parts.first?.lowercased() else { return }
        switch verb {
        case "ls":
            print(tree.focused.jsonString())
        case "map":
            print(tabs.map.introspectionNode.jsonString())
        case "stats":
            printStats(tabs)
        case "cams":
            let limit = parts.count > 1 ? Int(parts[1]) : 20
            await runCams(tabs, arguments: limit.map { ["--limit", String($0)] } ?? [])
        case "tab":
            if let i = parts.count > 1 ? Int(parts[1]) : nil { tabs.selected = i }
            print("{\"tab\":\(tabs.selected)}")
        case "do":
            guard parts.count >= 2 else { print("{\"error\":\"usage: do <Action> [json]\"}"); return }
            let rest = String(parts[1])
            let tokens = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let actionName = String(tokens[0])
            let inputData = tokens.count > 1 ? tokens[1].data(using: .utf8) : nil
            guard let action = tree.focused.actions.first(where: { $0.title == actionName }) else {
                print("{\"error\":\"unknown action\",\"available\":\(tree.focused.actionTitles())}")
                return
            }
            do {
                try await action.perform(inputData)
                print(tree.focused.jsonString())
            } catch { print("{\"error\":\"\(error)\"}") }
        default: print("{\"error\":\"unknown command: \(verb)\"}")
        }
    }

    @MainActor
    static func printStats(_ tabs: AtlasTabs) {
        print("walks      \(tabs.walks.walks.count)  months \(tabs.walks.months.count)")
        print("places     \(tabs.places.places.count)")
        print("flights    \(tabs.flights.flights.count)")
        print("parcels    \(tabs.parcels.parcels.count)")
        print("stations   \(tabs.tfl.stations.count)")
        if tabs.cameras.cameras.isEmpty {
            print("cameras    0  (run `cams` for the live TfL feed)")
        } else {
            print("cameras    \(tabs.cameras.cameras.count)  online \(tabs.cameras.onlineCount)")
        }
        if let first = tabs.walks.walks.first {
            print("latest     \(first.title ?? "walk") · \(first.startDate.formatted(date: .abbreviated, time: .omitted))")
        }
    }

    // MARK: - Benchmark

    @MainActor
    static func runBench(_ arguments: [String]) async {
        var iterations = 5
        var label = "current"
        var outPath: String?
        var comparePath: String?
        var json = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--iterations":
                if index + 1 < arguments.count { iterations = max(1, Int(arguments[index + 1]) ?? iterations) }
                index += 2
            case "--label":
                if index + 1 < arguments.count { label = arguments[index + 1] }
                index += 2
            case "--out":
                if index + 1 < arguments.count { outPath = arguments[index + 1] }
                index += 2
            case "--compare":
                if index + 1 < arguments.count { comparePath = arguments[index + 1] }
                index += 2
            case "--json":
                json = true
                index += 1
            default:
                index += 1
            }
        }

        guard let snapshot = AtlasDataLocation.existingDataFile() else {
            print("no snapshot found at \(AtlasDataLocation.defaultDataFile().path)")
            print("run `just import-data` first, or set ATLAS_DATA_FILE")
            return
        }

        do {
            let report = try await AtlasBenchmark.run(snapshotURL: snapshot, iterations: iterations, label: label)
            if let comparePath {
                let url = URL(fileURLWithPath: (comparePath as NSString).expandingTildeInPath)
                let baseline = try BenchmarkReport.decode(from: Data(contentsOf: url))
                print(AtlasBenchmark.compare(baseline: baseline, current: report))
            } else {
                print(report.text())
            }
            if json { print(report.jsonString()) }
            if let outPath {
                let url = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(report.jsonString().utf8).write(to: url, options: .atomic)
                print("wrote \(url.path)")
            }
        } catch {
            print("benchmark failed: \(error)")
        }
    }

    // MARK: - Cameras

    @MainActor
    static func runCams(_ tabs: AtlasTabs, arguments: [String]) async {
        var limit = 20
        if let index = arguments.firstIndex(of: "--limit"), index + 1 < arguments.count {
            limit = max(1, Int(arguments[index + 1]) ?? limit)
        }
        let started = Date()
        await tabs.cameras.refresh(force: true)
        let elapsed = Date().timeIntervalSince(started)
        if let error = tabs.cameras.errorMessage { print("error: \(error)") }
        let updated = tabs.cameras.lastUpdated?.formatted(date: .omitted, time: .shortened) ?? "—"
        print("cameras    \(tabs.cameras.cameras.count)  online \(tabs.cameras.onlineCount)  updated \(updated)  (\(String(format: "%.2f", elapsed))s)")
        for camera in tabs.cameras.cameras.prefix(limit) {
            let state = camera.isAvailable ? "live" : "offline"
            let image = camera.imageURL?.absoluteString ?? "—"
            print("\(camera.id) | \(camera.name) | \(camera.view) | \(String(format: "%.5f,%.5f", camera.coordinate.latitude, camera.coordinate.longitude)) | \(state) | \(image)")
        }
    }

    // MARK: - Import

    static func runImport(_ arguments: [String]) {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key.hasPrefix("--"), index + 1 < arguments.count {
                options[String(key.dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }

        guard let gpx = options["gpx"], let out = options["out"] else {
            print("usage: atlas-cli import --gpx <dir> [--places <csv>] [--transport <csv>] [--airports <csv>] --out <json>")
            return
        }

        do {
            let (data, report) = try AtlasImporter.build(
                gpxDirectory: URL(fileURLWithPath: (gpx as NSString).expandingTildeInPath),
                placesCSV: options["places"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
                transportCSV: options["transport"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
                airportsCSV: options["airports"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            )
            let outputURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            try AtlasImporter.write(data, to: outputURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
            print(report.text)
            print("wrote \(outputURL.path) (\(size / 1_048_576) MB)")
        } catch {
            print("import failed: \(error)")
        }
    }
}
