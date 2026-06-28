import AppIntents
import Foundation

/// Siri / Shortcuts / Spotlight entry point: "What's the score in StatBar?".
/// Compiled into the main app target (no extension) — works because StatBar is
/// a long-running menu-bar agent, so the intent runs in-process against the same
/// cache the popup paints from. Reads cache, not the network: the running app's
/// refresh loop keeps it fresh, and an intent should answer instantly offline.
@available(macOS 13.0, *)
struct GetScoresIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Live Scores" }
    static var description: IntentDescription {
        IntentDescription("Tells you what's happening right now across your followed leagues.")
    }
    // Don't yank the menu-bar popup open; just speak/show the answer.
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let matches = await APIService.shared.loadCachedMatches()
        let (teams, affinity) = await MainActor.run {
            (UserPreferencesManager.shared.followedTeams,
             UserPreferencesManager.shared.interestScores)
        }
        let ranked = MatchFocus.ranked(matches, followedTeams: teams, affinity: affinity)
        return .result(dialog: IntentDialog(stringLiteral: Self.summary(ranked)))
    }

    /// Pick the most relevant thing to say: live games first (already ranked, so
    /// the top of the list is the followed/closest one), else the next fixture,
    /// else the latest final, else nothing on.
    static func summary(_ ranked: [Match]) -> String {
        let live = ranked.filter(\.isLive)
        if !live.isEmpty {
            return live.prefix(3).map(line).joined(separator: ". ")
        }
        if let next = ranked.first(where: { !$0.isLive && !$0.isFinal }) {
            return "Nothing live. Next up: \(line(next))."
        }
        if let final = ranked.first(where: \.isFinal) {
            return "Nothing live. Latest final: \(line(final))."
        }
        return "No matches on right now."
    }

    static func line(_ m: Match) -> String {
        if m.isLive {
            let clock = m.gameClock.isEmpty ? "" : " (\(m.gameClock))"
            return "\(m.homeTeam) \(m.homeScore)–\(m.awayScore) \(m.awayTeam)\(clock)"
        }
        if m.isFinal {
            return "\(m.homeTeam) \(m.homeScore)–\(m.awayScore) \(m.awayTeam), full time"
        }
        return "\(m.homeTeam) vs \(m.awayTeam)"
    }
}

/// Donates the intent to Spotlight + Siri with spoken phrases. An
/// `AppShortcutsProvider` is auto-discovered at launch — no registration call.
@available(macOS 13.0, *)
struct StatBarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetScoresIntent(),
            phrases: [
                "What's the score in \(.applicationName)",
                "Get scores in \(.applicationName)",
                "\(.applicationName) live scores",
            ],
            shortTitle: "Live Scores",
            systemImageName: "sportscourt"
        )
    }
}
