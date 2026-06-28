import Foundation

/// Smart Focus Mode (roadmap §2).
///
/// The score feed is snapshot-only, so "what matters right now" has to be
/// derived from each match's own state. `MatchFocus` assigns every match a
/// relevance score from a few weighted signals — a followed team playing, a
/// live game, a nail-biter, overtime, a race leader — and exposes ordering +
/// primary-pick helpers shared by the menu bar and the popup. No manual
/// pinning: the most relevant live event surfaces on its own.
enum MatchFocus {
    /// Weighted relevance for a single match. Higher = more worth surfacing.
    ///
    /// `affinity` is the user's learned interest — `UserPreferencesManager`'s
    /// running count of detail/team-page opens, keyed by team token (lowercased)
    /// and league id. It adds a *small, capped* tiebreak bonus so leagues and
    /// teams you keep opening drift up among otherwise-equal games, without ever
    /// outranking a live game or a followed team.
    static func score(_ match: Match, followedTeams: [Team], affinity: [String: Int] = [:]) -> Int {
        var score = 0

        // Live games dominate; recently finished still beat anything upcoming.
        switch match.status.lowercased() {
        case "live", "in": score += 1000
        case "final", "post": score += 300
        default: score += 50
        }

        // A followed team playing is the strongest preference signal.
        if involvesFollowedTeam(match, followedTeams: followedTeams) {
            score += 600
        }

        // Drama signals only meaningful while live.
        if match.isLive {
            if isOvertime(match) { score += 350 }
            if isCloseGame(match) { score += 250 }
        }

        score += interestBonus(match, affinity: affinity)

        return score
    }

    /// Learned-interest tiebreak: capped sum of the two teams' and the league's
    /// open counts. Max +120 — below the close-game weight (+250), so it only
    /// reorders games that are otherwise tied. Empty `affinity` = no bonus.
    /// ponytail: linear cap, no decay — opens are rare and a stale count just
    /// nudges; add time-decay only if a season's history starts to dominate.
    static func interestBonus(_ match: Match, affinity: [String: Int]) -> Int {
        guard !affinity.isEmpty else { return 0 }
        let interest = (affinity[match.homeTeam.lowercased()] ?? 0)
            + (affinity[match.awayTeam.lowercased()] ?? 0)
            + (affinity[match.league] ?? 0)
        return min(interest, 8) * 15
    }

    /// Matches ordered most- to least-relevant (stable for equal scores).
    static func ranked(_ matches: [Match], followedTeams: [Team], affinity: [String: Int] = [:]) -> [Match] {
        matches
            .enumerated()
            .sorted { lhs, rhs in
                let ls = score(lhs.element, followedTeams: followedTeams, affinity: affinity)
                let rs = score(rhs.element, followedTeams: followedTeams, affinity: affinity)
                if ls != rs { return ls > rs }
                return lhs.offset < rhs.offset // preserve feed order on ties
            }
            .map { $0.element }
    }

    /// The single most relevant match, or nil if none.
    static func primary(_ matches: [Match], followedTeams: [Team], affinity: [String: Int] = [:]) -> Match? {
        ranked(matches, followedTeams: followedTeams, affinity: affinity).first
    }

    // MARK: - Followed-team companion (menu-bar continuity)

    /// The single match that should represent the user's followed teams in the
    /// menu bar — a season-long companion that tracks *your* team rather than the
    /// globally hottest game. Per followed team, picks (in priority): a live
    /// match, else a match that finished within `graceWindow` (so you catch the
    /// full-time score), else that team's *next* upcoming fixture. Across teams,
    /// live beats a recent final beats an upcoming kickoff; among upcoming the
    /// soonest wins. Returns nil when no followed team has any of the three (e.g.
    /// off-season with no scheduled next match) — the caller then falls back to
    /// ordinary Smart Focus.
    ///
    /// `firstSeenFinal` maps a matchID to when the app *first observed it final*;
    /// the snapshot feed carries no end-time, so the grace window is measured from
    /// that local observation. Pure (takes `now`) so it's deterministically
    /// testable.
    static func companion(
        forFollowed teams: [Team],
        in matches: [Match],
        firstSeenFinal: [String: Date],
        now: Date,
        graceWindow: TimeInterval
    ) -> Match? {
        // tier 0 = live, 1 = recent final, 2 = upcoming. `key` breaks ties within
        // a tier: most-recent for live/final, soonest for upcoming.
        var candidates: [(tier: Int, key: Date, match: Match)] = []
        for team in teams {
            let mine = matches.filter { followedSide($0, followedTeams: [team]) != nil }
            if let live = mine.first(where: { $0.isLive }) {
                candidates.append((0, now, live))
            } else if let fin = mine.compactMap({ m -> (Date, Match)? in
                guard m.isFinal, let seen = firstSeenFinal[m.matchID],
                      now.timeIntervalSince(seen) < graceWindow else { return nil }
                return (seen, m)
            }).max(by: { $0.0 < $1.0 }) {
                candidates.append((1, fin.0, fin.1))
            } else if let next = mine.compactMap({ m -> (Date, Match)? in
                guard !m.isLive, !m.isFinal, let kickoff = m.kickoff, kickoff > now else { return nil }
                return (kickoff, m)
            }).min(by: { $0.0 < $1.0 }) {
                candidates.append((2, next.0, next.1))
            }
        }
        return candidates.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            return a.tier == 2 ? a.key < b.key   // soonest upcoming
                               : a.key > b.key   // most-recent live/final
        }.first?.match
    }

    // MARK: - Signals

    /// True when the match is in overtime / extra time, read from the clock and
    /// detail strings the feeds surface ("OT", "2OT", "ET", "Extra Time", "SO").
    static func isOvertime(_ match: Match) -> Bool {
        let haystack = "\(match.gameClock) \(match.detail)".uppercased()
        for needle in ["OT", "OVERTIME", "EXTRA TIME", "ET", "SHOOTOUT", "SO", "AET"] {
            if haystack.contains(needle) { return true }
        }
        return false
    }

    /// A live game worth watching minute-to-minute: in overtime, or a tight
    /// margin. Drives clutch polling (`DataRefreshManager`) — the refresh loop
    /// tightens cadence while any visible match is clutch, so a buzzer-beater
    /// finish updates in seconds instead of on the normal live interval.
    static func isClutch(_ match: Match) -> Bool {
        match.isLive && (isOvertime(match) || isCloseGame(match))
    }

    /// True when the live score margin is within a sport-specific threshold.
    static func isCloseGame(_ match: Match) -> Bool {
        let margin = abs(match.homeScore - match.awayScore)
        // Soccer: a one-goal game is the close-game threshold.
        return margin <= 1
    }

    /// Fuzzy team match against the followed list. The feed uses abbreviations
    /// ("ARS") while followed teams are full names ("Arsenal"); match on
    /// substring either way or any whole-word overlap. Mirrors the logic in
    /// NotificationService so menu bar, popup, and alerts agree on "your team".
    static func involvesFollowedTeam(_ match: Match, followedTeams: [Team]) -> Bool {
        followedSide(match, followedTeams: followedTeams) != nil
    }

    /// The match's own team token (homeTeam / awayTeam, as the feed spells it)
    /// that belongs to a followed team, or nil. Used to emphasize the followed
    /// side in the menu bar and popup without a badge. Same fuzzy rule as above.
    static func followedSide(_ match: Match, followedTeams: [Team]) -> String? {
        guard !followedTeams.isEmpty else { return nil }
        let sides = [match.homeTeam, match.awayTeam].filter { !$0.isEmpty }
        for team in followedTeams where team.sport == match.sport {
            let name = team.name.lowercased()
            let nameWords = Set(name.split(separator: " "))
            for side in sides {
                let lower = side.lowercased()
                if name.contains(lower) || lower.contains(name) { return side }
                if !nameWords.isDisjoint(with: Set(lower.split(separator: " "))) { return side }
            }
        }
        return nil
    }
}
