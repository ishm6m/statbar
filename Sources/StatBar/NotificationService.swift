import Foundation
import UserNotifications

/// macOS notifications for live match events (PRD §8 / Session 8).
///
/// The score feed is snapshot-only — there are no event objects — so this
/// service diffs each refresh against the previous snapshot to derive events:
/// a match going live, a score change, a finish, and an F1 lead change. Events
/// are filtered by the user's enabled sports and followed teams, then posted
/// through `UNUserNotificationCenter`.
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let permissionRequestedKey = "StatBarNotifPermissionRequested"
    private let dedup = NotificationDeduplicator()

    /// Action + category identifiers for the "Open StatBar" button.
    private let openActionID = "STATBAR_OPEN"
    private let categoryID = "STATBAR_MATCH"

    /// Called when the user taps a notification (or its Open button) — wired by
    /// AppDelegate to focus the menu bar popup.
    var onOpenStatBar: (() -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - Setup

    /// Registers the delegate + notification category. Call once at launch.
    func configure(onOpenStatBar: @escaping () -> Void) {
        self.onOpenStatBar = onOpenStatBar
        center.delegate = self

        let openAction = UNNotificationAction(
            identifier: openActionID,
            title: "Open StatBar",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Requests notification permission once, on first launch after onboarding.
    /// (No onboarding flow exists yet — this fires at first launch for now.)
    func requestPermissionIfNeeded() {
        guard !defaults.bool(forKey: permissionRequestedKey) else { return }
        defaults.set(true, forKey: permissionRequestedKey)

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.notifications.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
            }
            Log.notifications.info("Notification authorization granted: \(granted, privacy: .public)")
            Task { @MainActor in DiagnosticsStore.shared.refreshNotificationAuth() }
        }
    }

    // MARK: - Diff → events

    /// Diffs two snapshots and posts a notification for each derived event the
    /// user opted into. `previous` empty (first refresh) establishes a baseline
    /// and emits nothing.
    func process(previous: [Match], current: [Match]) {
        let prefs = UserPreferencesManager.shared
        let enabled = prefs.enabledLeagues
        let teams = prefs.followedTeams
        let previousByID = Dictionary(previous.map { ($0.matchID, $0) }, uniquingKeysWith: { a, _ in a })

        for match in current {
            // Only leagues the user enabled.
            guard enabled.contains(match.league) else { continue }
            // Followed-team filter: if teams set, match must involve one;
            // if no teams set, all enabled leagues pass (PRD §8.4).
            if !teams.isEmpty, !matchInvolvesFollowedTeam(match, teams: teams) { continue }

            // No previous snapshot for this match → baseline, skip.
            guard let prev = previousByID[match.matchID] else { continue }

            // Match starting: transitioned into live.
            if prefs.notifyMatchStarting, !prev.isLive, match.isLive {
                postMatchStarting(match)
            }

            // Final score: transitioned into final.
            if prefs.notifyFinalScore, !prev.isFinal, match.isFinal {
                postFinalScore(match)
            }

            // Score change while live.
            if prefs.notifyGoals, match.isLive,
               prev.homeScore != match.homeScore || prev.awayScore != match.awayScore {
                postScore(match)
            }

            // Overtime: a live game just entered OT / extra time.
            if prefs.notifyGoals, match.isLive,
               !MatchFocus.isOvertime(prev), MatchFocus.isOvertime(match) {
                postOvertime(match)
            }

            // Lead change: the team in front flipped while live. Ignore ties and
            // pre-game 0-0.
            if prefs.notifyGoals, match.isLive {
                let before = prev.homeScore - prev.awayScore
                let after = match.homeScore - match.awayScore
                if after != 0, (before > 0) != (after > 0), before != after {
                    postScoreLeadChange(match)
                }
            }
        }
    }

    /// Best-effort fuzzy match: the feed uses abbreviations ("ARS") while
    /// followed teams are full names ("Arsenal"). Match if either
    /// string contains the other, or any whole word overlaps.
    private func matchInvolvesFollowedTeam(_ match: Match, teams: [Team]) -> Bool {
        let sides = [match.homeTeam, match.awayTeam].map { $0.lowercased() }
        for team in teams where team.sport == match.sport {
            let name = team.name.lowercased()
            for side in sides where !side.isEmpty {
                if name.contains(side) || side.contains(name) { return true }
                let nameWords = Set(name.split(separator: " "))
                let sideWords = Set(side.split(separator: " "))
                if !nameWords.isDisjoint(with: sideWords) { return true }
            }
        }
        return false
    }

    // MARK: - Notification builders

    private func postMatchStarting(_ match: Match) {
        let id = NotificationDeduplicator.eventID(matchID: match.matchID, type: "match_starting")
        guard dedup.shouldSend(id) else { return }
        AnalyticsService.notificationSent(type: "match_starting", sport: match.sport)
        post(
            title: "\(match.sport.emoji) \(match.sport.displayName) Starting Soon",
            body: "\(match.homeTeam) vs \(match.awayTeam) is kicking off",
            timeSensitive: false
        )
    }

    private func postScore(_ match: Match) {
        // State = scoreline, so each distinct score fires once but a repeat of
        // the same scoreline across cycles is suppressed.
        let id = NotificationDeduplicator.eventID(
            matchID: match.matchID, type: "score",
            state: "\(match.homeScore)-\(match.awayScore)")
        guard dedup.shouldSend(id) else { return }
        AnalyticsService.notificationSent(type: "score", sport: match.sport)
        let clock = match.gameClock.isEmpty ? "" : " (\(match.gameClock))"
        post(
            title: "\(match.sport.emoji) \(scoreWord(for: match.sport))",
            body: "\(match.homeTeam) \(match.homeScore)-\(match.awayScore) \(match.awayTeam)\(clock)",
            timeSensitive: false
        )
    }

    private func postFinalScore(_ match: Match) {
        let id = NotificationDeduplicator.eventID(
            matchID: match.matchID, type: "final_score",
            state: "\(match.homeScore)-\(match.awayScore)")
        guard dedup.shouldSend(id) else { return }
        AnalyticsService.notificationSent(type: "final_score", sport: match.sport)
        post(
            title: "\(match.sport.emoji) Final",
            body: "\(match.homeTeam) \(match.homeScore), \(match.awayTeam) \(match.awayScore)",
            timeSensitive: true
        )
    }

    private func postOvertime(_ match: Match) {
        let id = NotificationDeduplicator.eventID(matchID: match.matchID, type: "overtime")
        guard dedup.shouldSend(id) else { return }
        AnalyticsService.notificationSent(type: "overtime", sport: match.sport)
        post(
            title: "\(match.sport.emoji) Overtime!",
            body: "\(match.homeTeam) \(match.homeScore)-\(match.awayScore) \(match.awayTeam) is heading to OT",
            timeSensitive: true
        )
    }

    private func postScoreLeadChange(_ match: Match) {
        let leader = match.homeScore > match.awayScore ? match.homeTeam : match.awayTeam
        // State = scoreline so each distinct lead flip fires once.
        let id = NotificationDeduplicator.eventID(
            matchID: match.matchID, type: "lead_change",
            state: "\(match.homeScore)-\(match.awayScore)")
        guard dedup.shouldSend(id) else { return }
        AnalyticsService.notificationSent(type: "lead_change", sport: match.sport)
        post(
            title: "\(match.sport.emoji) Lead Change",
            body: "\(leader) now lead \(match.homeTeam) \(match.homeScore)-\(match.awayScore) \(match.awayTeam)",
            timeSensitive: false
        )
    }

    /// Word for a scoring event.
    private func scoreWord(for sport: Sport) -> String {
        "GOAL!"
    }

    // MARK: - Posting

    private func post(title: String, body: String, timeSensitive: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryID
        // .timeSensitive only for final scores so in-game updates respect Focus
        // modes (PRD §8.5).
        content.interruptionLevel = timeSensitive ? .timeSensitive : .active

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                Log.notifications.error("Delivery failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.notifications.info("Notification delivered")
            }
        }
    }
}

// MARK: - Delegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show notifications even when StatBar is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tap on the notification or its Open button focuses the popup.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.onOpenStatBar?()
        }
        completionHandler()
    }
}
