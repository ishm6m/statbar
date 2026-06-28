import Foundation

/// Single source of truth for every secret, endpoint, and integration toggle
/// (PRD v1.0 §5). Nothing else in the codebase hard-codes a URL or token.
///
/// Build-variant values: anything that should differ between development and a
/// shipped build is selected via `#if DEBUG`. Placeholder values (the
/// `REPLACE_WITH_…` sentinels) leave the corresponding integration disabled —
/// `isConfigured` checks below return `false`, and each call site no-ops rather
/// than firing against a bogus endpoint.
enum Config {

    // MARK: - PostHog analytics

    enum Analytics {
        /// Project API key from posthog.com → Project Settings. While left as
        /// the placeholder the SDK never initializes (see `isConfigured`).
        static let projectToken = "phc_REPLACE_WITH_POSTHOG_PROJECT_KEY"
        static let host = "https://us.i.posthog.com"

        /// True once a real `phc_…` token is set. Analytics stay off otherwise,
        /// so dev builds never phone home.
        static var isConfigured: Bool {
            projectToken.hasPrefix("phc_") && !projectToken.contains("REPLACE_WITH")
        }
    }

    // MARK: - Updates (FreeUpdateChecker)

    enum Updates {
        /// Endpoint for the lightweight, dependency-free update check (see
        /// `FreeUpdateChecker`). Serves the `version.json` at the repo root via
        /// raw GitHub; the manifest's `downloadURL` points at the latest Release.
        /// ponytail: assumes the app repo is github.com/ishm6m/statbar — fix if renamed.
        static let versionManifestURL = URL(string: "https://raw.githubusercontent.com/ishm6m/statbar/main/version.json")!

        /// Whether to run an update check automatically at app launch. On — the
        /// check is silent (popup only when a newer version exists) and throttled
        /// to once per day inside `FreeUpdateChecker.checkForUpdatesInBackground`.
        static let checkOnLaunch = true
    }

    // MARK: - Score API endpoints

    enum API {
        static let espnBase = "https://site.api.espn.com/apis/site/v2/sports"

        /// Scoreboard URL for a league, addressed by its two ESPN path segments
        /// (`sports/{sportSlug}/{leagueSlug}/scoreboard`). The generic provider
        /// builds every league's request through here.
        ///
        /// A `?dates=` window is appended: ESPN's bare `/scoreboard` returns only
        /// the current day, so the popup reads empty on off-days and the Next-Up
        /// card has nothing to surface. Widening to a few days back/forward pulls
        /// in recent finals and upcoming fixtures (drives Next-Up + Smart Focus)
        /// without flooding the popup list, which is capped at 5 rows.
        static func espnScoreboard(sportSlug: String, leagueSlug: String) -> URL? {
            guard var components = URLComponents(
                string: "\(espnBase)/\(sportSlug)/\(leagueSlug)/scoreboard"
            ) else { return nil }
            components.queryItems = [URLQueryItem(name: "dates", value: scoreboardDateRange())]
            return components.url
        }

        /// ESPN `?dates=` value: a `YYYYMMDD-YYYYMMDD` rolling window of yesterday
        /// through a week out. The window is wide enough that an off-by-one from
        /// timezone differences is harmless.
        static func scoreboardDateRange(now: Date = Date()) -> String {
            let cal = Calendar.current
            let start = cal.date(byAdding: .day, value: -1, to: now) ?? now
            // +14d (was +7) so a followed team's *next* fixture is in range even
            // across an international break or a sparse week — drives the menu-bar
            // companion handoff (MatchFocus.companion).
            let end = cal.date(byAdding: .day, value: 14, to: now) ?? now
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd"
            return "\(f.string(from: start))-\(f.string(from: end))"
        }

        /// Per-event summary URL (`sports/{sportSlug}/{leagueSlug}/summary?event={id}`).
        /// Carries the rich play-by-play (`keyEvents`: goals, cards, subs) the
        /// scoreboard omits. Fetched lazily, only when a game's detail view is
        /// opened — never on the polling loop — so it adds no fan-out.
        static func espnSummary(sportSlug: String, leagueSlug: String, event: String) -> URL? {
            guard var components = URLComponents(
                string: "\(espnBase)/\(sportSlug)/\(leagueSlug)/summary"
            ) else { return nil }
            components.queryItems = [URLQueryItem(name: "event", value: event)]
            return components.url
        }

        /// A team's season schedule (`sports/{sportSlug}/{leagueSlug}/teams/{teamId}/schedule`)
        /// — past results and upcoming fixtures with scores. Backs the team page,
        /// fetched lazily only when a team page opens, never on the poll loop.
        static func espnTeamSchedule(sportSlug: String, leagueSlug: String, teamId: String, season: Int? = nil) -> URL? {
            guard var components = URLComponents(
                string: "\(espnBase)/\(sportSlug)/\(leagueSlug)/teams/\(teamId)/schedule"
            ) else { return nil }
            if let season { components.queryItems = [URLQueryItem(name: "season", value: "\(season)")] }
            return components.url
        }

        /// League standings table (`apis/v2/sports/{sportSlug}/{leagueSlug}/standings`).
        /// Note the path is `apis/v2/...`, NOT the scoreboard's `apis/site/v2/...`.
        /// Fed to the popup's empty state so an off-day shows the league table
        /// instead of a dead screen. Fetched lazily, only when there are no games.
        static func espnStandings(sportSlug: String, leagueSlug: String) -> URL? {
            URL(string: "https://site.api.espn.com/apis/v2/sports/\(sportSlug)/\(leagueSlug)/standings")
        }
    }

    /// Menu-bar focus tuning.
    enum Focus {
        /// How long a followed team's finished match keeps showing its full-time
        /// score in the menu bar before the companion handoff advances to that
        /// team's next fixture (MatchFocus.companion). 10 minutes — long enough to
        /// catch the result, short enough it isn't stale clutter.
        static let gracePeriod: TimeInterval = 10 * 60
    }
}
