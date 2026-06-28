import Foundation

/// How live scores are rendered in the macOS menu bar.
/// Persisted in UserDefaults via `UserPreferencesManager.displayMode`.
///
/// Six user-selectable styles, leanest → richest, in two groups —
/// text (sport-emoji fallbacks) then logo (real crests / country flags):
///
///   .scoreOnly     2–1
///   .teamScore     ARS 2–1 CHE
///   .detailed      ARS 2–1 CHE · 78'
///   .logoScore     🅰 2–1 🅱
///   .logoTeam      🅰 ARS 2–1 CHE 🅱
///   .logoDetailed  🅰 ARS 2–1 CHE 🅱 · 78'
///
/// Each mode still adapts: when the richest form can't fit the available menu
/// bar width it falls back through leaner candidates so the title never clips.
/// The logo modes render real crest/flag images and are handled on a separate
/// image path in `AppDelegate`; their string entries here are the text fallback
/// used for width math and when a crest hasn't loaded yet.
enum DisplayMode: String, CaseIterable, Codable, Identifiable {
    case scoreOnly
    case teamScore
    case detailed
    case logoScore
    case logoScoreDetailed
    case logoTeam
    case logoDetailed

    var id: String { rawValue }

    /// The image-rendered modes (crest/flag inline). Drives the separate
    /// attributed-image build in `AppDelegate.updateMenuBarLabel`.
    var usesLogos: Bool { self == .logoScore || self == .logoScoreDetailed || self == .logoTeam || self == .logoDetailed }

    /// Whether this mode appends the game-clock context ("· 78'" / "· FT").
    var showsContext: Bool { self == .detailed || self == .logoScoreDetailed || self == .logoDetailed }

    /// Whether this mode shows short team names alongside the score.
    var showsTeams: Bool { self == .teamScore || self == .detailed || self == .logoTeam || self == .logoDetailed }

    var displayName: String {
        switch self {
        case .scoreOnly: return "Score"
        case .teamScore: return "Teams + Score"
        case .detailed: return "Detailed"
        case .logoScore: return "Logo + Score"
        case .logoScoreDetailed: return "Logo + Score + Detailed"
        case .logoTeam: return "Logo + Teams"
        case .logoDetailed: return "Logo + Detailed"
        }
    }

    var subtitle: String {
        switch self {
        case .scoreOnly: return "Score only"
        case .teamScore: return "Short team names + score"
        case .detailed: return "Teams, score, and game clock"
        case .logoScore: return "Club crests / country flags + score"
        case .logoScoreDetailed: return "Crests, score, and game clock"
        case .logoTeam: return "Crests, short team names, and score"
        case .logoDetailed: return "Crests, teams, score, and game clock"
        }
    }

    /// Adaptive menu-bar candidates for the primary match, ordered richest →
    /// leanest. The status bar picks the first that fits the available width.
    /// `matches` is already filtered to active sports and ranked by Smart Focus,
    /// so the first live/final match is the focus pick.
    func menuBarCandidates(for matches: [Match]) -> [String] {
        let liveOrFinal = matches.filter { $0.status == "live" || $0.status == "final" }
        guard let primary = liveOrFinal.first else {
            return ["StatBar"]
        }

        let emoji = primary.sport.emoji
        let score = "\(primary.homeScore)–\(primary.awayScore)" // en-dash
        // Team modes are emoji-free by design: "ARS 2–1 CHE".
        let teams = "\(primary.homeTeam) \(score) \(primary.awayTeam)"
        let emojiScore = "\(emoji) \(score)"

        // Rich context (quarter / period / OT / Final) shown when space permits.
        let context = Self.contextLabel(for: primary)
        let detailed = context.isEmpty ? teams : "\(teams) · \(context)"

        switch self {
        case .scoreOnly:
            return [score, emoji]
        case .teamScore:
            return [teams, emojiScore, score, emoji]
        case .detailed:
            return [detailed, teams, emojiScore, score, emoji]
        // Logo modes: text fallback for width math / unloaded crests.
        case .logoScore:
            return [score, emoji]
        case .logoScoreDetailed:
            let scoreContext = context.isEmpty ? score : "\(score) · \(context)"
            return [scoreContext, score, emoji]
        case .logoTeam:
            return [teams, score, emoji]
        case .logoDetailed:
            return [detailed, teams, score, emoji]
        }
    }

    /// Adaptive candidates for a pinned game that hasn't kicked off yet. Mirrors
    /// the live ladder but swaps the score for the start time, so the menu bar
    /// reads "ARS vs CHE · 7:30 PM" instead of a fake 0–0. Generic copy ("vs",
    /// time) — no league/broadcaster marks.
    func upcomingMenuBarCandidates(for match: Match) -> [String] {
        let emoji = match.sport.emoji
        let start = match.menuBarStartText
        let teams = "\(match.homeTeam) vs \(match.awayTeam)"
        let emojiStart = "\(emoji) \(start)"
        let detailed = "\(teams) · \(start)"

        switch self {
        case .scoreOnly:
            return [start, emoji]
        case .teamScore:
            return [teams, emojiStart, start, emoji]
        case .detailed:
            return [detailed, teams, emojiStart, start, emoji]
        case .logoScore:
            return [start, emoji]
        case .logoScoreDetailed:
            return [emojiStart, start, emoji]
        case .logoTeam:
            return [teams, start, emoji]
        case .logoDetailed:
            return [detailed, teams, start, emoji]
        }
    }

    /// Compact game-state label for the menu bar: "FT"/"AET" (soccer full-time),
    /// or the live game clock ("78'", "45'+2"). Empty when there's nothing useful.
    static func contextLabel(for match: Match) -> String {
        if match.status == "final" { return MatchFocus.isOvertime(match) ? "AET" : "FT" }
        if match.isLive, MatchFocus.isOvertime(match) { return "OT" }
        let clock = match.gameClock.trimmingCharacters(in: .whitespaces)
        return clock
    }

    /// Static example used in the Settings preview, independent of live data.
    var previewExample: String {
        switch self {
        case .scoreOnly: return "2–1"
        case .teamScore: return "ARS 2–1 CHE"
        case .detailed: return "ARS 2–1 CHE · 78'"
        case .logoScore: return "🔴 2–1 🔵"
        case .logoScoreDetailed: return "🔴 2–1 🔵 · 78'"
        case .logoTeam: return "🔴 ARS 2–1 CHE 🔵"
        case .logoDetailed: return "🔴 ARS 2–1 CHE 🔵 · 78'"
        }
    }
}
