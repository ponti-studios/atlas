import Foundation
import Network

/// A tiny debug-only TCP server that exposes an introspection tree over a port,
/// mirroring the `walks-cli` command protocol. Compiled into debug builds only
/// by the host app.
@MainActor
public final class ReflexServer {
    private let tree: IntrospectionTree
    private let port: UInt16
    private var listener: NWListener?
    public var extraHandler: ((String) async -> String?)?

    public init(tree: IntrospectionTree, port: UInt16 = 8765, extraHandler: ((String) async -> String?)? = nil) {
        self.tree = tree
        self.port = port
        self.extraHandler = extraHandler
    }

    public func start() {
        do {
            let params = NWParameters.tcp
            let port = self.port
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.handle(conn) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    // A busy port (for example the macOS app already running) is the
                    // usual cause; say so rather than silently losing the listener.
                    print("ReflexServer failed on port \(port): \(error)")
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            print("ReflexServer failed to start: \(error)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if isComplete || error != nil || buf.contains(0x0A) {
                    let text = String(data: buf, encoding: .utf8) ?? ""
                    let response = await self.processCommand(text)
                    let out = (response + "\n").data(using: .utf8) ?? Data()
                    connection.send(content: out, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } else {
                    self.receive(on: connection, buffer: buf)
                }
            }
        }
    }

    private func processCommand(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        if let extraHandler, let r = await extraHandler(trimmed) { return r }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let verb = parts.first?.lowercased() else { return "{}" }
        switch verb {
        case "ls":
            return tree.focused.jsonString()
        case "do":
            guard parts.count >= 2 else { return "{\"error\":\"usage: do <Action> [json]\"}" }
            let rest = String(parts[1])
            let tokens = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let actionName = String(tokens[0])
            let jsonStr = tokens.count > 1 ? String(tokens[1]) : nil
            let inputData = jsonStr?.data(using: .utf8)
            guard let action = tree.focused.actions.first(where: { $0.title == actionName }) else {
                return "{\"error\":\"unknown action: \(actionName)\"}"
            }
            do {
                try await action.perform(inputData)
                return tree.focused.jsonString()
            } catch {
                return "{\"error\":\"\(error)\"}"
            }
        default:
            return "{\"error\":\"unknown command: \(verb)\"}"
        }
    }
}