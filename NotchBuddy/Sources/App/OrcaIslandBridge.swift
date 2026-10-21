import AppKit
import Combine
import Observation

/// User settings for paired remote Orca servers (`--environment`), kept in UserDefaults.
enum OrcaHostSettings {
    /// Include remote hosts in the counters and the list (default on).
    static let includeKey = "orcaIncludeRemoteHosts"
    /// Ids of the hosts the user turned off, comma separated (ids are UUIDs).
    static let disabledKey = "orcaDisabledHostIds"

    static var include: Bool { UserDefaults.standard.object(forKey: includeKey) as? Bool ?? true }
    static var disabledIds: Set<String> { parse(UserDefaults.standard.string(forKey: disabledKey) ?? "") }

    static func parse(_ raw: String) -> Set<String> { Set(raw.split(separator: ",").map(String.init)) }
    static func encode(_ ids: Set<String>) -> String { ids.sorted().joined(separator: ",") }
}

/// Feeds the island with Orca data: owns the `OrcaStore`, mirrors its snapshot into `AppState`, and
/// tells the store what the app is doing so it can pick the poll rate (OrcaPollPolicy):
/// fast while the island is on screen, slow while it is hidden or the Mac / screen sleeps.
@MainActor
final class OrcaIslandBridge {
    static let shared = OrcaIslandBridge()

    let store = OrcaStore()
    private var cancellables = Set<AnyCancellable>()
    private var asleep = false
    private var started = false
    private var keepsVisible = false

    func start() {
        guard !started else { return }
        started = true
        let state = AppState.shared

        // Island visibility drives the poll rate.
        state.$mode
            .map { $0 != .hidden }
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyActivity() }
            .store(in: &cancellables)

        // Sleep / wake of the Mac and of the screens.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.publisher(for: name).sink { [weak self] _ in self?.asleep = true; self?.applyActivity() }
                .store(in: &cancellables)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.publisher(for: name).sink { [weak self] _ in self?.asleep = false; self?.applyActivity() }
                .store(in: &cancellables)
        }

        // Remote-host settings: read now and whenever Settings changes them (the store ignores no-ops).
        applyHostSettings()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.applyHostSettings() }
            .store(in: &cancellables)

        applyActivity()
        store.start()
        track()
    }

    private func applyHostSettings() {
        store.includeEnvironments = OrcaHostSettings.include
        store.disabledEnvironmentIds = OrcaHostSettings.disabledIds
    }

    private func applyActivity() {
        store.setActivity(islandVisible: AppState.shared.mode != .hidden, asleep: asleep)
    }

    /// Re-armed observation of the store's snapshot (Observation fires once per change).
    private func track() {
        withObservationTracking {
            _ = store.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.publish()
                self?.track()
            }
        }
    }

    private func publish() {
        let state = AppState.shared
        let snapshot = store.snapshot
        state.setIfChanged(\.orca, snapshot)
        let visible = snapshot.agentCounts.keepsIslandVisible
        guard visible != keepsVisible else { return }
        keepsVisible = visible
        let fsm = (NSApp.delegate as? AppDelegate)?.islandController?.fsm
        if visible { fsm?.reveal() } else { fsm?.resumeHideTimer() }
        state.syncMode()
    }
}
