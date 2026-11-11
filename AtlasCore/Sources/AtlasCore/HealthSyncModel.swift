import Foundation
import Combine

/// What the UI needs to know about the Health connection. Lives in the core so
/// the sidebar can show it without importing HealthKit, and so the iOS sync can
/// be driven from a test double.
@MainActor
public final class HealthSyncModel: ObservableObject {
    public enum State: Equatable {
        case unavailable
        case needsPermission
        case syncing
        case synced(Int)
        case failed(String)

        public var summary: String {
            switch self {
            case .unavailable: return "Health is not available here"
            case .needsPermission: return "Connect Apple Health"
            case .syncing: return "Syncing walks…"
            case .synced(let count): return "\(count) walks synced"
            case .failed(let message): return message
            }
        }

        public var isBusy: Bool {
            if case .syncing = self { return true }
            return false
        }

        public var needsAction: Bool {
            switch self {
            case .needsPermission, .failed: return true
            default: return false
            }
        }
    }

    @Published public private(set) var state: State = .unavailable
    @Published public private(set) var lastSyncedAt: Date?

    private var runner: (() async -> Void)?

    public init() {}

    /// The platform installs the work here; the view only calls `activate()`.
    public func attach(runner: @escaping () async -> Void) {
        self.runner = runner
    }

    /// What the button does: ask for permission the first time, then sync.
    public func activate() async {
        guard let runner else { return }
        await runner()
    }

    public func report(_ state: State) {
        self.state = state
    }

    public func reportSynced(count: Int, at date: Date) {
        lastSyncedAt = date
        state = .synced(count)
    }
}
