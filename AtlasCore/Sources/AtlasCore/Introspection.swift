import Foundation

public struct IntrospectionAction {
    public let title: String
    public let inputSchema: String?
    public let perform: (Data?) async throws -> Void
}
public struct IntrospectionNode {
    public let name: String
    public let stateJSON: String
    public let actions: [IntrospectionAction]
    public let child: (() -> IntrospectionNode?)?
    /// Optional ambient state (for example the map camera) that lives above a leaf node.
    public let contextJSON: String?

    public init(
        name: String,
        stateJSON: String,
        actions: [IntrospectionAction],
        child: (() -> IntrospectionNode?)?,
        contextJSON: String? = nil
    ) {
        self.name = name
        self.stateJSON = stateJSON
        self.actions = actions
        self.child = child
        self.contextJSON = contextJSON
    }

    public func actionTitles() -> [String] { actions.map(\.title) }

    public func appending(actions extra: [IntrospectionAction], contextJSON: String? = nil) -> IntrospectionNode {
        IntrospectionNode(
            name: name,
            stateJSON: stateJSON,
            actions: actions + extra,
            child: child,
            contextJSON: contextJSON ?? self.contextJSON
        )
    }

    public func toJSON() -> [String: Any] {
        var payload: [String: Any] = [
            "name": name,
            "state": (try? JSONSerialization.jsonObject(with: Data(stateJSON.utf8))) ?? stateJSON,
            "actions": actions.map { ["title": $0.title] },
        ]
        if let contextJSON,
           let context = try? JSONSerialization.jsonObject(with: Data(contextJSON.utf8)) {
            payload["context"] = context
        }
        return payload
    }

    public func jsonString() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: toJSON(), options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
public protocol Introspectable: AnyObject { var introspectionNode: IntrospectionNode { get } }

extension WalksViewModel: Introspectable {
    public var introspectionNode: IntrospectionNode {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let stateJSON = String(data: (try? encoder.encode(state)) ?? Data(), encoding: .utf8) ?? "{}"
        let vm = self
        return IntrospectionNode(name: "Walks", stateJSON: stateJSON, actions: [
            IntrospectionAction(title: "Refresh", inputSchema: nil) { _ in await vm.refresh(force: true) },
            IntrospectionAction(title: "ClearFilter", inputSchema: nil) { _ in await vm.clearFilter() },
            IntrospectionAction(title: "LoadNextPage", inputSchema: nil) { _ in await vm.loadNextPage() },
        ], child: nil)
    }
}
private struct PlaceIntrospectionState: Codable {
    let count: Int
    let selectedID: UUID?
    let isLoading: Bool
    let errorMessage: String?
    let query: String
    let isSearching: Bool
    let results: [PlaceSearchResult]
}

extension PlacesViewModel: Introspectable {
    public var introspectionNode: IntrospectionNode {
        // Do not encode the whole place list over Reflex; summary only.
        let summary = PlaceIntrospectionState(
            count: state.places.count,
            selectedID: state.selectedPlace?.id,
            isLoading: state.isLoading,
            errorMessage: state.errorMessage,
            query: state.query,
            isSearching: state.isSearching,
            results: state.results
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let stateJSON = String(data: (try? encoder.encode(summary)) ?? Data(), encoding: .utf8) ?? "{}"
        let vm = self
        return IntrospectionNode(name: "Places", stateJSON: stateJSON, actions: [
            IntrospectionAction(title: "Refresh", inputSchema: nil) { _ in await vm.refresh() },
            IntrospectionAction(title: "SearchAppleMaps", inputSchema: "{\"query\":\"...\"}") { input in
                let query = Self.string(in: input, key: "query") ?? ""
                await vm.search(query)
            },
            IntrospectionAction(title: "SaveSearchResult", inputSchema: "{\"index\":0}") { input in
                let index = Self.integer(in: input, key: "index") ?? 0
                await vm.save(resultAt: index)
            },
            IntrospectionAction(title: "ClearSearch", inputSchema: nil) { _ in vm.clearResults() },
        ], child: nil)
    }

    private static func string(in input: Data?, key: String) -> String? {
        guard let input, let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        return object[key] as? String
    }

    private static func integer(in input: Data?, key: String) -> Int? {
        guard let input, let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        if let value = object[key] as? Int { return value }
        if let value = object[key] as? Double { return Int(value) }
        return nil
    }
}
extension FlightsViewModel: Introspectable {
    public var introspectionNode: IntrospectionNode {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let stateJSON = String(data: (try? encoder.encode(state)) ?? Data(), encoding: .utf8) ?? "{}"
        let vm = self
        return IntrospectionNode(name: "Flights", stateJSON: stateJSON, actions: [
            IntrospectionAction(title: "Refresh", inputSchema: nil) { _ in await vm.refresh() },
        ], child: nil)
    }
}
extension ParcelsViewModel: Introspectable {
    public var introspectionNode: IntrospectionNode {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let stateJSON = String(data: (try? encoder.encode(state)) ?? Data(), encoding: .utf8) ?? "{}"
        let vm = self
        return IntrospectionNode(name: "Parcels", stateJSON: stateJSON, actions: [
            IntrospectionAction(title: "Refresh", inputSchema: nil) { _ in await vm.refresh() },
        ], child: nil)
    }
}
extension TFLViewModel: Introspectable {
    public var introspectionNode: IntrospectionNode {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let stateJSON = String(data: (try? encoder.encode(state)) ?? Data(), encoding: .utf8) ?? "{}"
        let vm = self
        return IntrospectionNode(name: "TFL", stateJSON: stateJSON, actions: [
            IntrospectionAction(title: "Refresh", inputSchema: nil) { _ in await vm.refresh() },
        ], child: nil)
    }
}

extension MapViewModel: Introspectable {
    public var introspectionNode: IntrospectionNode {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let stateJSON = String(data: (try? encoder.encode(state)) ?? Data(), encoding: .utf8) ?? "{}"
        let vm = self
        return IntrospectionNode(name: "Map", stateJSON: stateJSON, actions: [
            IntrospectionAction(title: "MapZoomIn", inputSchema: nil) { _ in vm.send(.zoom(by: 1.7)) },
            IntrospectionAction(title: "MapZoomOut", inputSchema: nil) { _ in vm.send(.zoom(by: 1 / 1.7)) },
            IntrospectionAction(title: "MapCycleStyle", inputSchema: nil) { _ in vm.send(.cycleStyle) },
            IntrospectionAction(title: "MapToggle3D", inputSchema: nil) { _ in vm.send(.toggle3D) },
            IntrospectionAction(title: "MapReset", inputSchema: nil) { _ in vm.send(.reset) },
        ], child: nil)
    }

    public var mapStateJSON: String { introspectionNode.stateJSON }
}
// MARK: - Cameras

private struct CameraIntrospectionState: Codable {
    let count: Int
    let online: Int
    let selectedID: String?
    let isLoading: Bool
    let errorMessage: String?
    let lastUpdated: Date?
}

extension CamerasViewModel: Introspectable {
    public var introspectionNode: IntrospectionNode {
        // Do not encode the full 889-camera array over Reflex; summary only.
        let summary = CameraIntrospectionState(
            count: cameras.count,
            online: onlineCount,
            selectedID: selectedID,
            isLoading: isLoading,
            errorMessage: errorMessage,
            lastUpdated: lastUpdated
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stateJSON = String(data: (try? encoder.encode(summary)) ?? Data(), encoding: .utf8) ?? "{}"
        let vm = self
        return IntrospectionNode(name: "Cameras", stateJSON: stateJSON, actions: [
            IntrospectionAction(title: "Refresh", inputSchema: nil) { _ in await vm.refresh(force: true) },
            IntrospectionAction(title: "SelectFirstCamera", inputSchema: nil) { _ in vm.selectFirstAvailable() },
            IntrospectionAction(title: "ClearSelection", inputSchema: nil) { _ in vm.select(nil) },
        ], child: nil)
    }
}
