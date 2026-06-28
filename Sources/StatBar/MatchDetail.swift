import Foundation

/// The expanded "story" of one soccer match, pulled from ESPN's per-event
/// `summary` endpoint. Fetched lazily when the user opens a game's detail view,
/// never on the polling loop. One call carries every section below.
struct MatchDetail: Equatable, Sendable {
    /// The owning `Match.matchID`, so a stale fetch can be discarded when the
    /// user has already moved to a different game.
    let matchID: String
    /// Key events (goals/cards/subs), most-recent-first.
    let events: [KeyEvent]
    /// Minute-by-minute commentary, most-recent-first.
    let commentary: [CommentaryItem]
    /// Side-by-side team statistics (possession, shots, xG, …) in feed order.
    let teamStats: [TeamStat]
    /// Starting XI + bench for each side, when the feed carries lineups.
    let homeLineup: Lineup?
    let awayLineup: Lineup?
    /// Match facts (venue, attendance, referee), label→value.
    let info: [InfoItem]
    /// League table, full group, in rank order; the two playing teams flagged.
    let standings: [StandingsRow]
    /// Each side's recent-form strip (last five, newest-first).
    let form: [FormGuide]
    /// Previous meetings between these two teams, newest-first.
    let headToHead: [HeadToHeadGame]
    /// Aggregate shooting picture: team shot funnel + top shooters by volume.
    let shots: ShotData
    /// Pre-match betting market (moneyline 3-way + spread + over/under) from the
    /// top sportsbook the feed lists. nil when no odds are carried.
    let odds: MatchOdds?

    init(matchID: String,
         events: [KeyEvent] = [],
         commentary: [CommentaryItem] = [],
         teamStats: [TeamStat] = [],
         homeLineup: Lineup? = nil,
         awayLineup: Lineup? = nil,
         info: [InfoItem] = [],
         standings: [StandingsRow] = [],
         form: [FormGuide] = [],
         headToHead: [HeadToHeadGame] = [],
         shots: ShotData = ShotData(),
         odds: MatchOdds? = nil) {
        self.matchID = matchID
        self.events = events
        self.commentary = commentary
        self.teamStats = teamStats
        self.homeLineup = homeLineup
        self.awayLineup = awayLineup
        self.info = info
        self.standings = standings
        self.form = form
        self.headToHead = headToHead
        self.shots = shots
        self.odds = odds
    }

    /// True when no section carried any content — drives the empty state.
    var isEmpty: Bool {
        events.isEmpty && commentary.isEmpty && teamStats.isEmpty
            && homeLineup == nil && awayLineup == nil && info.isEmpty
            && standings.isEmpty && form.isEmpty && headToHead.isEmpty
            && shots.isEmpty && odds == nil
    }
}

/// One sportsbook's market for a match: three-way moneyline (home / draw / away)
/// plus the handicap (spread) line and the over/under goals total. Values arrive
/// pre-formatted: moneylines as American odds ("+320", "-180"), the rest as the
/// feed gives them. Any field may be empty when that market isn't quoted.
struct MatchOdds: Equatable, Sendable {
    /// Sportsbook name, e.g. "DraftKings".
    let provider: String
    /// Team abbreviations for the moneyline row labels, e.g. "USA" / "MEX".
    let homeTeam: String
    let awayTeam: String
    /// American moneylines, e.g. "-180" / "+320" / "+500". Empty when unquoted.
    let homeMoneyline: String
    let drawMoneyline: String
    let awayMoneyline: String
    /// Handicap line as the feed phrases it, e.g. "USA -0.5". Empty when absent.
    let spread: String
    /// Over/under goals total, e.g. "2.5". Empty when absent.
    let overUnder: String

    var isEmpty: Bool {
        homeMoneyline.isEmpty && drawMoneyline.isEmpty && awayMoneyline.isEmpty
            && spread.isEmpty && overUnder.isEmpty
    }
}

/// Aggregate shooting view for a match. ESPN's public summary carries no
/// expected-goals (xG) anywhere — player or team — so this is built from raw
/// shot counts only; no perpetually-blank xG column is shown (req 7).
struct ShotData: Equatable, Sendable {
    /// Team shot funnel (Shots / On Target / Blocked), home vs away, in funnel
    /// order. Reuses `TeamStat` so the comparison bars render identically.
    let teamShots: [TeamStat]
    /// Individual shooters, ranked by shot volume (most active first).
    let shooters: [Shooter]

    init(teamShots: [TeamStat] = [], shooters: [Shooter] = []) {
        self.teamShots = teamShots
        self.shooters = shooters
    }

    var isEmpty: Bool { teamShots.isEmpty && shooters.isEmpty }
}

/// One player's shooting line: shots taken, on target, and goals.
struct Shooter: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Team abbreviation the player shot for, e.g. "PAL".
    let team: String
    let shots: Int
    let onTarget: Int
    let goals: Int
}

/// One row of the league table. Values come pre-formatted from the feed.
struct StandingsRow: Identifiable, Equatable, Sendable {
    /// Stable id = rank+team (a table never repeats a team).
    var id: String { "\(rank)-\(team)" }
    let rank: String
    /// Full team name as the feed gives it, e.g. "Palmeiras".
    let team: String
    let played: String
    /// Win-draw-loss record, e.g. "12-5-1".
    let record: String
    /// Goal difference, signed, e.g. "+17".
    let goalDiff: String
    let points: String
    /// True for the two teams in the open match, so the table highlights them.
    let isMatchTeam: Bool
}

/// A team's recent-form strip: the side plus its last-five results newest-first.
struct FormGuide: Identifiable, Equatable, Sendable {
    var id: String { team }
    /// Team abbreviation, e.g. "PAL".
    let team: String
    let results: [FormResult]
}

/// One recent result on a form strip.
struct FormResult: Identifiable, Equatable, Sendable {
    let id: String
    let outcome: Outcome
    /// Tooltip line, e.g. "W 4-1 vs JAC · 14 May".
    let summary: String

    enum Outcome: Sendable {
        case win, draw, loss, unknown

        /// Maps ESPN's `gameResult` ("W"/"D"/"L") onto an outcome.
        static func from(_ raw: String?) -> Outcome {
            switch (raw ?? "").uppercased() {
            case "W": return .win
            case "D", "T": return .draw
            case "L": return .loss
            default: return .unknown
            }
        }
    }
}

/// One previous meeting between the two teams.
struct HeadToHeadGame: Identifiable, Equatable, Sendable {
    let id: String
    /// Short date, e.g. "14 May 26".
    let date: String
    /// "PAL 2-0 CHA" style line as seen from the home side of that meeting.
    let line: String
    /// Result for the open match's first-listed team, for a tint.
    let outcome: FormResult.Outcome
}

/// One minute-by-minute commentary line.
struct CommentaryItem: Identifiable, Equatable, Sendable {
    let id: String
    /// Clock label, e.g. "67'". May be empty for pre/post lines.
    let clock: String
    let text: String
}

/// One row of the team-stats comparison: a label with each side's value as the
/// feed formatted it (e.g. "61.9%", "10", "1.34").
struct TeamStat: Identifiable, Equatable, Sendable {
    /// Stable id = the stat label.
    var id: String { label }
    let label: String
    let home: String
    let away: String
    /// Home/away as fractions of their sum when both parse as numbers, for the
    /// comparison bar. nil when a value isn't numeric (keeps text-only stats).
    var split: (home: Double, away: Double)? {
        guard let h = Self.numeric(home), let a = Self.numeric(away), h + a > 0 else { return nil }
        return (h / (h + a), a / (h + a))
    }

    private static func numeric(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }
}

/// A team's lineup: formation string plus starters and substitutes.
struct Lineup: Equatable, Sendable {
    /// e.g. "4-3-3". Empty when the feed omits it.
    let formation: String
    let starters: [LineupPlayer]
    let subs: [LineupPlayer]
}

/// One player on a lineup.
struct LineupPlayer: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Shirt number, e.g. "9". Empty when missing.
    let jersey: String
    /// Position abbreviation, e.g. "GK", "CF". Empty when missing.
    let position: String
    /// Marks a player who came on / went off, for the ⇄ glyph.
    let subbedIn: Bool
    let subbedOut: Bool
}

/// One match fact, e.g. ("Venue", "Wembley Stadium").
struct InfoItem: Identifiable, Equatable, Sendable {
    var id: String { label }
    let label: String
    let value: String
}

/// One entry on a game's key-events timeline.
struct KeyEvent: Identifiable, Equatable, Sendable {
    let id: String
    /// Clock/period label, e.g. "25'".
    let clock: String
    /// Short type label from the feed, e.g. "Goal", "Yellow Card".
    let typeText: String
    /// Full human sentence, e.g. "Goal! Aston Villa 0, Wolves 1. Matheus Cunha…"
    let text: String
    /// Coarse kind, drives the leading glyph + tint.
    let kind: Kind
    /// Scoring team abbreviation, when the feed names one.
    let teamAbbrev: String?
    /// Running score after this play, e.g. "2-1"; nil when the score lives in `text`.
    let runningScore: String?

    init(id: String, clock: String, typeText: String, text: String, kind: Kind,
         teamAbbrev: String? = nil, runningScore: String? = nil) {
        self.id = id
        self.clock = clock
        self.typeText = typeText
        self.text = text
        self.kind = kind
        self.teamAbbrev = teamAbbrev
        self.runningScore = runningScore
    }

    enum Kind: Sendable {
        case goal
        case yellowCard
        case redCard
        case substitution
        /// A generic score in a non-soccer sport (kept for compatibility).
        case score
        case other

        /// SF Symbol shown at the row's leading edge.
        var symbol: String {
            switch self {
            case .goal: return "soccerball"
            case .yellowCard, .redCard: return "rectangle.portrait.fill"
            case .substitution: return "arrow.left.arrow.right"
            case .score: return "circle.fill"
            case .other: return "circle.fill"
            }
        }

        /// Maps an ESPN `keyEvents[].type.text` string onto a kind. Order matters:
        /// "Red Card" must be tested before the substring "Card".
        static func from(typeText: String) -> Kind {
            let t = typeText.lowercased()
            if t.contains("goal") { return .goal }
            if t.contains("red") { return .redCard }
            if t.contains("yellow") { return .yellowCard }
            if t.contains("substitution") || t.contains("sub") { return .substitution }
            return .other
        }
    }
}
