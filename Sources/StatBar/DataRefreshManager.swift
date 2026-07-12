import Foundation

/// Drives the score refresh loop.
///
/// Reliability guarantees:
/// - Each fetch is timed; latency + timestamp are reported to `DiagnosticsStore`.
/// - A fetch that comes back empty while we already hold data is treated as a
///   transient failure: the previous snapshot is kept so the UI never blanks
///   out on a hiccup — never clear the UI to an empty state.
/// - On repeated empty results the poll interval backs off geometrically up to
///   a ceiling, so a sustained outage doesn't hammer the network.
@MainActor
final class DataRefreshManager {
    private let apiService: APIService
    private let maxBackoff: TimeInterval = 600

    /// Live/idle intervals come from the user's chosen `RefreshSpeed`, read fresh
    /// each cycle so a change in Settings takes effect on the next scheduled
    /// refresh without restarting the loop.
    private var refreshIntervalLive: TimeInterval {
        UserPreferencesManager.shared.refreshSpeed.liveInterval
    }
    private var refreshIntervalIdle: TimeInterval {
        UserPreferencesManager.shared.refreshSpeed.idleInterval
    }

    private var timer: Timer?
    private var currentMatches: [Match] = []
    private var failureStreak = 0

    var onUpdate: (([Match]) -> Void)?

    init(apiService: APIService = .shared) {
        self.apiService = apiService
    }

    func start() {
        timer?.invalidate()
        refreshNow()
        scheduleNextRefresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Force an immediate refresh (e.g. on regained connectivity).
    func refreshImmediately() {
        refreshNow()
    }

    private func refreshNow() {
        // Skip the round-trip entirely when we know we're offline; keep showing
        // the last known data instead of forcing a doomed request.
        guard NetworkMonitor.shared.isOnline else {
            Log.network.notice("Refresh skipped — offline")
            failureStreak += 1
            scheduleNextRefresh()
            return
        }

        Task {
            let started = Date()
            let matches = await apiService.fetchAllMatches()
            let latency = Date().timeIntervalSince(started)

            await MainActor.run {
                DiagnosticsStore.shared.recordRefresh(latency: latency)

                if matches.isEmpty && !self.currentMatches.isEmpty {
                    // Transient: keep the last good snapshot, don't blank the UI.
                    self.failureStreak += 1
                    Log.api.notice("Empty result with cached data present — keeping last known (\(self.currentMatches.count, privacy: .public) matches)")
                } else {
                    self.currentMatches = matches
                    self.failureStreak = 0
                    self.onUpdate?(matches)
                    Log.api.info("Refreshed \(matches.count, privacy: .public) matches in \(Int(latency * 1000), privacy: .public) ms")
                }
                self.scheduleNextRefresh()
            }
        }
    }

    private func scheduleNextRefresh() {
        timer?.invalidate()

        // Only enabled leagues drive cadence — a clutch game the user can't see
        // shouldn't spin the network. Mirrors the menu-bar/popup visibility scope.
        let enabled = UserPreferencesManager.shared.enabledLeagues
        let visible = currentMatches.filter { enabled.contains($0.league) }

        let speed = UserPreferencesManager.shared.refreshSpeed
        let base: TimeInterval
        if visible.contains(where: { MatchFocus.isClutch($0) }) {
            // Buzzer-beater territory: poll on the tight clutch cadence.
            base = speed.clutchInterval
        } else if visible.contains(where: { $0.status == "live" }) {
            base = refreshIntervalLive
        } else {
            base = refreshIntervalIdle
        }

        // Geometric backoff on sustained failure, capped.
        let interval: TimeInterval
        if failureStreak > 0 {
            interval = min(base * pow(2, Double(failureStreak)), maxBackoff)
        } else {
            interval = base
        }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }
}
