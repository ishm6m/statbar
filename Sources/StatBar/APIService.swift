import Foundation

struct Match: Codable, Equatable {
    let sport: Sport
    /// League id (e.g. "eng.1") — the polling unit and `LeagueCatalog` key.
    /// `sport` stays the category.
    let league: String
    let homeTeam: String
    let awayTeam: String
    let homeScore: Int
    let awayScore: Int
    let status: String
    let gameClock: String
    let detail: String
    /// Official team logo URL from the API response, when present; nil falls
    /// back to the guessed CDN path in `LogoProvider`.
    let homeLogo: String?
    let awayLogo: String?
    /// Scheduled kickoff, parsed from the feed's ISO date; drives the local
    /// start-time shown for pre-game rows instead of a raw feed clock string.
    let kickoff: Date?
    /// ESPN web link to the game's box score / gamecast, from the feed's
    /// `event.links`; nil hides the "View on ESPN" action.
    let gameURL: String?
    /// Primary team brand colors as ESPN hex strings (e.g. "0b162a"), used for a
    /// subtle accent under each hero team; nil renders no accent.
    let homeColor: String?
    let awayColor: String?
    /// ESPN's numeric event id (e.g. "704319"), used to address the per-event
    /// `summary` endpoint; nil hides the detail drill-down for that game.
    let espnEventID: String?
    /// ESPN numeric team ids (e.g. "359"), used to address each team's schedule
    /// endpoint; nil hides the team-page drill-down for that side.
    let homeTeamID: String?
    let awayTeamID: String?
    /// Human competition stage for this match (e.g. "Group Stage", "Round of 16",
    /// "Quarterfinal · 1st Leg"). Derived from ESPN's per-event `season.slug` plus
    /// any leg/round `notes`; nil for plain domestic-league fixtures.
    let stage: String?

    /// Stable identifier for analytics. The feed has no match id, so derive one
    /// from the league + both teams (lowercased, hyphenated). League-scoped so
    /// the same fixture in two competitions never collides.
    var matchID: String {
        "\(league)-\(homeTeam)-\(awayTeam)"
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    var isLive: Bool {
        status.lowercased() == "live" || status.lowercased() == "in"
    }

    var isFinal: Bool {
        status.lowercased() == "final" || status.lowercased() == "post"
    }

    /// Local start time for a scheduled game (e.g. "Today 8:00 PM", "Sat 8:00 PM").
    /// Falls back to the feed's clock string, then a plain "Scheduled", so a row
    /// is never blank.
    var scheduledTimeText: String {
        guard let kickoff else {
            return gameClock.isEmpty ? "Scheduled" : gameClock
        }
        let cal = Calendar.current
        let time = kickoff.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(kickoff) { return "Today \(time)" }
        if cal.isDateInTomorrow(kickoff) { return "Tomorrow \(time)" }
        let day = kickoff.formatted(.dateTime.weekday(.abbreviated))
        return "\(day) \(time)"
    }

    /// Tight kickoff label for the menu bar when a not-yet-started game is pinned:
    /// just the clock for today ("7:30 PM"), prefixed with the weekday otherwise
    /// ("Sat 7:30 PM"). Keeps the pinned-upcoming title short.
    var menuBarStartText: String {
        guard let kickoff else { return "Scheduled" }
        let time = kickoff.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(kickoff) { return time }
        let day = kickoff.formatted(.dateTime.weekday(.abbreviated))
        return "\(day) \(time)"
    }

}

actor APIService {
    static let shared = APIService()

    private init() {}

    func fetchAllMatches() async -> [Match] {
        let leagues = await UserPreferencesManager.shared.activeLeagues

        // Fan out: every league fetch is independent, so run them concurrently
        // instead of serially — total refresh latency becomes the slowest single
        // league, not the sum of all of them. Matters as the catalog grows.
        // Results are reassembled in catalog (priority) order so the popup and
        // Smart Focus see a stable, deterministic ordering regardless of which
        // request finished first. A single league's failure still falls back to
        // its own cache without affecting the rest (see `fetchESPNMatches`).
        let indexed = await withTaskGroup(of: (Int, [Match]).self) { group in
            for (index, league) in leagues.enumerated() {
                group.addTask { (index, await self.fetchESPNMatches(for: league)) }
            }
            var collected: [(Int, [Match])] = []
            for await result in group { collected.append(result) }
            return collected
        }

        return indexed.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }

    func loadCachedMatches() async -> [Match] {
        await UserPreferencesManager.shared.activeLeagues.flatMap { loadCachedMatches(for: $0.id) }
    }

    private func loadCachedMatches(for leagueID: String) -> [Match] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: leagueID)),
              let matches = try? JSONDecoder().decode([Match].self, from: data) else {
            return []
        }
        return matches
    }

    private func save(_ matches: [Match], for leagueID: String) {
        if let encoded = try? JSONEncoder().encode(matches) {
            UserDefaults.standard.set(encoded, forKey: cacheKey(for: leagueID))
        }
    }

    private func cacheKey(for leagueID: String) -> String {
        // v2: `Match` dropped its multi-sport fields and custom decode; older
        // cached blobs are simply abandoned and repopulated on the next fetch.
        "StatBarCachedMatches_v2_\(leagueID.uppercased())"
    }

    private func fetchESPNMatches(for league: LeagueDefinition) async -> [Match] {
        guard let url = Config.API.espnScoreboard(
            sportSlug: LeagueDefinition.espnSportSlug, leagueSlug: league.id
        ) else { return loadCachedMatches(for: league.id) }

        do {
            let data = try await fetchData(from: url)
            let matches = try decodeESPNMatches(from: data, league: league)
            save(matches, for: league.id)
            return matches
        } catch {
            Log.api.error("\(league.displayName, privacy: .public) refresh failed: \(error.localizedDescription, privacy: .public) — serving cache")
            return loadCachedMatches(for: league.id)
        }
    }

    // MARK: - Standings (empty-state table)

    /// League table for the popup's empty state — when a scoped league has no
    /// games, ESPN shows its standings rather than a blank screen. Lazy: fetched
    /// only on an off-day, never on the poll loop. No disk cache — on failure it
    /// returns `[]` and the popup falls back to its league suggestions.
    /// ponytail: no cache; off-day fetch is rare and the empty list degrades fine.
    /// `highlight` flags the matching row (by name overlap) as `isMatchTeam` so
    /// the team page can emphasize the team whose page is open. Nil = no highlight
    /// (the empty-state caller).
    func fetchStandings(for league: LeagueDefinition, highlight: String? = nil) async -> [StandingsRow] {
        guard let url = Config.API.espnStandings(
            sportSlug: LeagueDefinition.espnSportSlug, leagueSlug: league.id
        ) else { return [] }

        do {
            let data = try await fetchData(from: url)
            let resp = try JSONDecoder().decode(StandingsResponse.self, from: data)
            let entries = resp.children?.first?.standings?.entries ?? []
            // The feed returns the table already sorted by position, so rank is
            // the row index — there's no per-entry rank stat in the v2 feed.
            return entries.enumerated().compactMap { idx, entry -> StandingsRow? in
                guard let name = entry.team?.shortDisplayName ?? entry.team?.displayName,
                      !name.isEmpty else { return nil }
                var byName: [String: StandingsStat] = [:]
                for s in entry.stats ?? [] { if let n = s.name { byName[n] = s } }
                let record = [byName["wins"], byName["ties"], byName["losses"]]
                    .compactMap { $0?.displayValue }.joined(separator: "-")
                return StandingsRow(
                    rank: "\(idx + 1)",
                    team: name,
                    played: byName["gamesPlayed"]?.displayValue ?? "",
                    record: record,
                    goalDiff: byName["pointDifferential"].map(Self.signedStat) ?? "",
                    points: byName["points"]?.displayValue ?? "",
                    isMatchTeam: highlight.map { Self.namesMatch($0, name) } ?? false
                )
            }
        } catch {
            Log.api.error("\(league.displayName, privacy: .public) standings failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Loose name overlap used to flag a team's standings row — abbreviations vs
    /// full names ("ARS" vs "Arsenal"), either way round.
    private static func namesMatch(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return x == y || x.contains(y) || y.contains(x)
    }

    /// Goal difference as a signed string ("+17", "-4"). Prefers the numeric
    /// `value` so the sign is reliable; falls back to the feed's displayValue.
    private static func signedStat(_ s: StandingsStat) -> String {
        guard let v = s.value else { return s.displayValue ?? "" }
        let n = Int(v.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }

    private struct StandingsResponse: Decodable { let children: [StandingsChild]? }
    private struct StandingsChild: Decodable { let standings: StandingsList? }
    private struct StandingsList: Decodable { let entries: [StandingsEntry]? }
    private struct StandingsEntry: Decodable {
        let team: StandingsTeam?
        let stats: [StandingsStat]?
    }
    private struct StandingsTeam: Decodable {
        let displayName: String?
        let shortDisplayName: String?
    }
    private struct StandingsStat: Decodable {
        let name: String?
        let displayValue: String?
        let value: Double?
    }

    // MARK: - Team page (lazy)

    /// Builds a team's page — recent results, upcoming fixtures, and the league
    /// table with the team highlighted — from the team-schedule endpoint plus the
    /// league standings, fetched concurrently. Returns nil only when the league
    /// can't be addressed; a failed schedule or table degrades to an empty section
    /// rather than blocking. Called only when a team page opens, never on the loop.
    func fetchTeamPage(leagueID: String, teamID: String, teamName: String) async -> TeamPage? {
        guard let league = LeagueCatalog.byID(leagueID) else { return nil }

        async let schedule = fetchTeamSchedule(league: league, teamID: teamID)
        async let table = fetchStandings(for: league, highlight: teamName)
        let (games, standings) = await (schedule, table)

        let results = games.filter(\.played)
            .sorted { ($0.kickoff ?? .distantPast) > ($1.kickoff ?? .distantPast) }
        let fixtures = games.filter { !$0.played }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
        return TeamPage(team: teamName, results: results, fixtures: fixtures, standings: standings)
    }

    private func fetchTeamSchedule(league: LeagueDefinition, teamID: String, season: Int? = nil) async -> [TeamGame] {
        guard let url = Config.API.espnTeamSchedule(
            sportSlug: LeagueDefinition.espnSportSlug, leagueSlug: league.id,
            teamId: teamID, season: season
        ) else { return [] }
        do {
            let data = try await fetchData(from: url)
            let (games, year) = decodeTeamSchedule(from: data, teamID: teamID)
            // Off-season: the bare endpoint returns the *upcoming* season, which
            // has no games yet — fall back once to the prior season so the page
            // shows last season's results rather than a dead screen.
            if games.isEmpty, season == nil, let year {
                return await fetchTeamSchedule(league: league, teamID: teamID, season: year - 1)
            }
            return games
        } catch {
            Log.api.error("Team schedule failed for \(teamID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private struct ScheduleResponse: Decodable {
        let events: [ScheduleEvent]?
        let season: ScheduleSeason?
    }
    private struct ScheduleSeason: Decodable { let year: Int? }
    private struct ScheduleEvent: Decodable {
        let id: String?
        let date: String?
        let competitions: [ScheduleComp]?
    }
    private struct ScheduleComp: Decodable {
        let competitors: [ScheduleCompetitor]?
        let status: ESPNScheduleStatus?
    }
    private struct ESPNScheduleStatus: Decodable { let type: ESPNScheduleStatusType? }
    private struct ESPNScheduleStatusType: Decodable { let completed: Bool? }
    private struct ScheduleCompetitor: Decodable {
        let homeAway: String?
        let winner: Bool?
        let score: FlexScore?
        let team: ScheduleTeam?
    }
    private struct ScheduleTeam: Decodable {
        let id: String?
        let abbreviation: String?
        let displayName: String?
    }
    /// A schedule `score` arrives as an object (`{value, displayValue}`) — unlike
    /// the scoreboard's bare String — so decode the value out of it.
    private struct FlexScore: Decodable {
        let displayValue: String
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                displayValue = s; return
            }
            struct Obj: Decodable { let displayValue: String? }
            displayValue = ((try? decoder.singleValueContainer().decode(Obj.self))?.displayValue) ?? ""
        }
    }

    /// Flattens a team's schedule into `TeamGame`s, resolving each event from the
    /// requested team's perspective (us vs the opponent) and reading the outcome
    /// from the `winner` flags so a played game is W/D/L without re-deriving it.
    private func decodeTeamSchedule(from data: Data, teamID: String) -> (games: [TeamGame], season: Int?) {
        guard let response = try? JSONDecoder().decode(ScheduleResponse.self, from: data) else { return ([], nil) }
        let games = (response.events ?? []).compactMap { event -> TeamGame? in
            guard let comp = event.competitions?.first,
                  let competitors = comp.competitors,
                  let us = competitors.first(where: { $0.team?.id == teamID }),
                  let opp = competitors.first(where: { $0.team?.id != teamID }) else { return nil }

            let played = comp.status?.type?.completed ?? false
            let outcome: FormResult.Outcome
            if !played { outcome = .unknown }
            else if us.winner == true { outcome = .win }
            else if opp.winner == true { outcome = .loss }
            else { outcome = .draw }

            // Score line in this team's order: our score – their score.
            let line = played
                ? "\(us.score?.displayValue ?? "")–\(opp.score?.displayValue ?? "")"
                : ""
            let oppName = opp.team?.abbreviation ?? opp.team?.displayName ?? "—"
            let kickoff = event.date.flatMap(Self.parseISODate)
            return TeamGame(
                id: event.id ?? "\(oppName)-\(event.date ?? "")",
                date: kickoff.map(Self.shortDate) ?? "",
                opponent: oppName,
                homeAway: us.homeAway == "away" ? "@" : "vs",
                line: line.trimmingCharacters(in: CharacterSet(charactersIn: "–")),
                outcome: outcome,
                played: played,
                kickoff: kickoff
            )
        }
        return (games, response.season?.year)
    }

    // MARK: - Networking with exponential backoff

    /// Non-retryable client errors (4xx) — retrying won't help.
    private struct ClientError: Error { let status: Int }

    /// GETs `url`, retrying transient failures with exponential backoff
    /// (0.5s → 1s → 2s). 4xx responses bail immediately. Throws after the last
    /// attempt so the caller can fall back to the on-disk cache.
    private func fetchData(from url: URL, maxAttempts: Int = 3) async throws -> Data {
        var delayNanos: UInt64 = 500_000_000
        var lastError: Error = URLError(.unknown)

        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if (400...499).contains(http.statusCode) {
                    throw ClientError(status: http.statusCode)
                }
                guard (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch let error as ClientError {
                throw error // permanent — no retry
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    Log.api.notice("Attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public) failed — backing off \(Double(delayNanos) / 1e9, privacy: .public)s")
                    try? await Task.sleep(nanoseconds: delayNanos)
                    delayNanos *= 2
                }
            }
        }
        throw lastError
    }

    /// ESPN scoreboard dates come as ISO8601 without seconds (e.g.
    /// "2026-06-20T17:00Z"), which the default `ISO8601DateFormatter` rejects.
    /// Try the standard parser first, then a seconds-less fallback.
    private nonisolated(unsafe) static let isoWithSeconds: ISO8601DateFormatter = .init()
    private static let isoNoSeconds: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        return f
    }()

    nonisolated static func parseISODate(_ raw: String) -> Date? {
        isoWithSeconds.date(from: raw) ?? isoNoSeconds.date(from: raw)
    }


    nonisolated func decodeESPNMatches(from data: Data, league: LeagueDefinition) throws -> [Match] {
        struct ESPNResponse: Decodable {
            let events: [ESPNEvent]
        }

        struct ESPNEvent: Decodable {
            let id: String?
            let date: String?
            let status: ESPNStatus
            let competitions: [ESPNCompetition]
            let links: [ESPNLink]?
            let season: ESPNSeason?
        }

        // Per-event season block. `slug` is the match's stage ("group-stage",
        // "round-of-16", "regular-season", …) — the match-accurate field, unlike
        // the league-level season which tracks the competition's current phase.
        struct ESPNSeason: Decodable {
            let slug: String?
        }

        struct ESPNNote: Decodable {
            let headline: String?
        }

        struct ESPNLink: Decodable {
            let rel: [String]?
            let href: String?
        }

        struct ESPNStatus: Decodable {
            let type: ESPNStatusType
            let displayClock: String?
        }

        struct ESPNStatusType: Decodable {
            let state: String
            let shortDetail: String?
        }

        struct ESPNCompetition: Decodable {
            let competitors: [ESPNCompetitor]
            let status: ESPNStatus?
            let notes: [ESPNNote]?
        }

        struct ESPNCompetitor: Decodable {
            let homeAway: String
            let team: ESPNTeam
            let score: String?
        }

        struct ESPNTeam: Decodable {
            let id: String?
            let abbreviation: String
            let displayName: String
            let logo: String?
            let color: String?
        }

        let response = try JSONDecoder().decode(ESPNResponse.self, from: data)

        return response.events.compactMap { event in
            guard let competition = event.competitions.first,
                  let home = competition.competitors.first(where: { $0.homeAway == "home" }),
                  let away = competition.competitors.first(where: { $0.homeAway == "away" }) else {
                return nil
            }

            let statusState = event.status.type.state.lowercased()
            let normalizedStatus: String
            switch statusState {
            case "in", "live": normalizedStatus = "live"
            case "post", "final", "complete": normalizedStatus = "final"
            case "pre", "scheduled", "tbd": normalizedStatus = "pre"
            default: normalizedStatus = statusState
            }

            // Between periods ESPN keeps state "in" but zeroes displayClock
            // ("0:00"); show the period text ("End of 1st") instead of a stalled
            // clock so a live game never reads "Live · 0:00".
            let rawClock = event.status.displayClock ?? ""
            let zeroClock = rawClock.isEmpty || rawClock == "0:00" || rawClock == "0.0"
            let gameClock = zeroClock ? (event.status.type.shortDetail ?? rawClock) : rawClock

            // Prefer the canonical desktop event link (box score / gamecast);
            // fall back to the summary link, then any link.
            func linkMatching(_ rels: Set<String>) -> String? {
                event.links?.first { Set($0.rel ?? []).isSuperset(of: rels) }?.href
            }
            let gameURL = linkMatching(["desktop", "event"])
                ?? linkMatching(["summary"])
                ?? event.links?.first?.href

            // Stage label: title-case the per-event season slug, hiding plain
            // regular-season; append any leg/round note (e.g. "1st Leg") so
            // knockout ties read "Quarterfinal · 1st Leg".
            let stage = Self.stageLabel(
                slug: event.season?.slug,
                note: competition.notes?.first?.headline
            )

            return Match(
                sport: league.sport,
                league: league.id,
                homeTeam: home.team.abbreviation,
                awayTeam: away.team.abbreviation,
                homeScore: Int(home.score ?? "0") ?? 0,
                awayScore: Int(away.score ?? "0") ?? 0,
                status: normalizedStatus,
                gameClock: gameClock,
                detail: event.status.type.shortDetail ?? "",
                homeLogo: home.team.logo,
                awayLogo: away.team.logo,
                kickoff: event.date.flatMap(Self.parseISODate),
                gameURL: gameURL,
                homeColor: home.team.color,
                awayColor: away.team.color,
                espnEventID: event.id,
                homeTeamID: home.team.id,
                awayTeamID: away.team.id,
                stage: stage
            )
        }
    }

    /// Build a human stage label from ESPN's per-event season `slug` and an
    /// optional leg/round `note`. Regular-season slugs (domestic leagues) return
    /// nil so league fixtures carry no stage clutter. Unmapped slugs fall back to
    /// title-casing the slug ("round-of-16" → "Round of 16"), so a stage we don't
    /// explicitly know still renders sensibly across all 17 competitions.
    nonisolated static func stageLabel(slug: String?, note: String?) -> String? {
        var slug = slug?.lowercased()
        // Domestic feeds put the season *name* in the per-event slug
        // ("2026-brasileiro-serie-a", "2025-26-english-premier-league"). A year
        // in the slug means season-name noise, not a stage — knockout slugs
        // never carry one — so treat it like regular season.
        if slug?.range(of: #"(19|20)\d{2}"#, options: .regularExpression) != nil {
            slug = nil
        }
        let base: String?
        switch slug {
        case nil, "", "regular-season", "regular season": base = nil
        case "round-of-16": base = "Round of 16"
        case "round-of-32": base = "Round of 32"
        case "quarterfinals", "quarterfinal": base = "Quarterfinal"
        case "semifinals", "semifinal": base = "Semifinal"
        case "final", "finals": base = "Final"
        default:
            // Title-case the slug: "group-stage" → "Group Stage".
            base = slug!.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
        let note = note?.trimmingCharacters(in: .whitespaces)
        switch (base, note) {
        case let (b?, n?) where !n.isEmpty: return "\(b) · \(n)"
        case let (b?, _): return b
        case let (nil, n?) where !n.isEmpty: return n
        default: return nil
        }
    }

    // MARK: - Per-event detail (lazy)

    /// Fetches the rich timeline (goals, cards, subs) for one game from ESPN's
    /// `summary` endpoint. Returns nil when the league/event can't be addressed
    /// or the request fails — the detail view then shows an empty state rather
    /// than blocking. Called only when a detail view opens, never on the loop.
    func fetchMatchDetail(for match: Match) async -> MatchDetail? {
        guard let league = LeagueCatalog.byID(match.league),
              let eventID = match.espnEventID,
              let url = Config.API.espnSummary(
                  sportSlug: LeagueDefinition.espnSportSlug,
                  leagueSlug: league.id,
                  event: eventID
              ) else { return nil }

        do {
            let data = try await fetchData(from: url)
            return decodeMatchDetail(from: data, matchID: match.matchID)
        } catch {
            Log.api.error("Detail fetch failed for \(match.matchID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Detail decoding

    private struct SummaryResponse: Decodable {
        let keyEvents: [SummaryEvent]?
        let commentary: [SummaryCommentary]?
        let boxscore: SummaryBoxscore?
        let rosters: [SummaryRoster]?
        let header: SummaryHeader?
        let gameInfo: SummaryGameInfo?
        let standings: SummaryStandings?
        let lastFiveGames: [SummaryTeamEvents]?
        let headToHeadGames: [SummaryTeamEvents]?
        let pickcenter: [SummaryPick]?
        let odds: [SummaryPick]?
    }
    // pickcenter / odds share a shape: one entry per sportsbook with a three-way
    // moneyline, a spread, and an over/under. ESPN labels the home/away/draw odds
    // explicitly, so we trust those rather than re-deriving sides.
    private struct SummaryPick: Decodable {
        let provider: SummaryProvider?
        let details: String?
        let overUnder: Double?
        let homeTeamOdds: SummaryTeamOdds?
        let awayTeamOdds: SummaryTeamOdds?
        let drawOdds: SummaryMoneyline?
    }
    private struct SummaryProvider: Decodable { let name: String?; let priority: Int? }
    private struct SummaryTeamOdds: Decodable { let moneyLine: Double? }
    private struct SummaryMoneyline: Decodable { let moneyLine: Double? }
    private struct SummaryEvent: Decodable {
        let id: String?
        let type: SummaryText?
        let text: String?
        let clock: SummaryClock?
    }
    private struct SummaryCommentary: Decodable {
        let sequence: Int?
        let text: String?
        let time: SummaryClock?
    }
    private struct SummaryBoxscore: Decodable { let teams: [SummaryBoxTeam]? }
    private struct SummaryBoxTeam: Decodable {
        let team: SummaryTeamRef?
        let statistics: [SummaryStat]?
    }
    private struct SummaryStat: Decodable {
        let name: String?
        let label: String?
        let displayValue: String?
    }
    private struct SummaryRoster: Decodable {
        let homeAway: String?
        let formation: String?
        let roster: [SummaryRosterPlayer]?
    }
    private struct SummaryRosterPlayer: Decodable {
        let starter: Bool?
        let jersey: String?
        let subbedIn: Bool?
        let subbedOut: Bool?
        let athlete: SummaryAthlete?
        let position: SummaryPosition?
        /// Per-player stat line (totalShots / shotsOnTarget / totalGoals / …).
        let stats: [SummaryStat]?
    }
    private struct SummaryAthlete: Decodable {
        let id: String?
        let displayName: String?
        let shortName: String?
    }
    private struct SummaryPosition: Decodable { let abbreviation: String? }
    private struct SummaryGameInfo: Decodable {
        let venue: SummaryVenue?
        let attendance: Int?
        let officials: [SummaryOfficial]?
    }
    private struct SummaryVenue: Decodable { let fullName: String? }
    private struct SummaryOfficial: Decodable { let displayName: String? }
    private struct SummaryText: Decodable { let text: String? }
    private struct SummaryClock: Decodable { let displayValue: String? }
    private struct SummaryTeamRef: Decodable {
        let id: String?
        let abbreviation: String?
        let displayName: String?
    }
    private struct SummaryHeader: Decodable { let competitions: [SummaryComp]? }
    private struct SummaryComp: Decodable { let competitors: [SummaryCompetitor]? }
    private struct SummaryCompetitor: Decodable {
        let homeAway: String?
        let team: SummaryTeamRef?
    }

    // Standings table: groups[].standings.entries[], each entry a team plus
    // named stats. The entry's `team` arrives as a plain display-name String in
    // the soccer feed (not the usual object), so decode it flexibly.
    private struct SummaryStandings: Decodable { let groups: [SummaryStandingsGroup]? }
    private struct SummaryStandingsGroup: Decodable { let standings: SummaryStandingsInner? }
    private struct SummaryStandingsInner: Decodable { let entries: [SummaryStandingsEntry]? }
    private struct SummaryStandingsEntry: Decodable {
        let team: FlexTeamName?
        let stats: [SummaryStandingStat]?
    }
    private struct SummaryStandingStat: Decodable {
        let name: String?
        let displayValue: String?
    }
    /// Accepts a standings `team` whether the feed gives a bare String or an
    /// object with `displayName`, so a schema shift in one league can't blank the
    /// whole table.
    private struct FlexTeamName: Decodable {
        let name: String
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                name = s
                return
            }
            struct Obj: Decodable { let displayName: String?; let abbreviation: String? }
            let o = try decoder.singleValueContainer().decode(Obj.self)
            name = o.displayName ?? o.abbreviation ?? ""
        }
    }

    // lastFiveGames / headToHeadGames share a shape: a team and its recent events.
    private struct SummaryTeamEvents: Decodable {
        let team: SummaryTeamRef?
        let events: [SummaryFormEvent]?
    }
    private struct SummaryFormEvent: Decodable {
        let id: String?
        let gameResult: String?
        let score: String?
        let gameDate: String?
        let atVs: String?
        let opponent: SummaryTeamRef?
    }

    /// Decodes an ESPN per-event soccer `summary` into a `MatchDetail`: key
    /// events, minute commentary, side-by-side team stats, lineups, and match
    /// facts — all from the one response.
    nonisolated func decodeMatchDetail(from data: Data, matchID: String) -> MatchDetail {
        guard let response = try? JSONDecoder().decode(SummaryResponse.self, from: data) else {
            return MatchDetail(matchID: matchID)
        }

        // Key events: feed is chronological (kickoff first); newest-first so the
        // latest goal sits at the top without scrolling.
        let events: [KeyEvent] = (response.keyEvents ?? []).enumerated().map { index, e in
            let typeText = e.type?.text ?? ""
            return KeyEvent(
                id: e.id ?? "\(index)",
                clock: e.clock?.displayValue ?? "",
                text: e.text ?? typeText,
                kind: KeyEvent.Kind.from(typeText: typeText)
            )
        }.reversed()

        // Commentary: also chronological → newest-first to match the timeline.
        let commentary: [CommentaryItem] = (response.commentary ?? []).enumerated().compactMap { index, c in
            guard let text = c.text, !text.isEmpty else { return nil }
            return CommentaryItem(
                id: c.sequence.map(String.init) ?? "\(index)",
                clock: c.time?.displayValue ?? "",
                text: text
            )
        }.reversed()

        let teamStats = Self.teamStats(from: response)
        let homeLineup = Self.lineup(from: response, side: "home")
        let awayLineup = Self.lineup(from: response, side: "away")
        let info = Self.info(from: response.gameInfo)
        let standings = Self.standings(from: response)
        let form = Self.form(from: response.lastFiveGames)
        let headToHead = Self.headToHead(from: response.headToHeadGames)
        let shots = Self.shots(from: response)
        let odds = Self.odds(from: response)

        return MatchDetail(
            matchID: matchID,
            events: Array(events),
            commentary: Array(commentary),
            teamStats: teamStats,
            homeLineup: homeLineup,
            awayLineup: awayLineup,
            info: info,
            standings: standings,
            form: form,
            headToHead: headToHead,
            shots: shots,
            odds: odds
        )
    }

    /// The match's betting market from the highest-priority sportsbook the feed
    /// lists. Prefers `pickcenter` (richer), falls back to `odds`; both carry the
    /// same shape. Returns nil when no usable line is quoted, so the Odds tab
    /// stays hidden rather than showing an empty control (req 7).
    private static func odds(from response: SummaryResponse) -> MatchOdds? {
        let picks = (response.pickcenter?.isEmpty == false ? response.pickcenter : response.odds) ?? []
        guard let pick = picks.min(by: { ($0.provider?.priority ?? .max) < ($1.provider?.priority ?? .max) }) else {
            return nil
        }
        var abbrevBySide: [String: String] = [:]
        for c in response.header?.competitions?.first?.competitors ?? [] {
            if let ha = c.homeAway, let ab = c.team?.abbreviation { abbrevBySide[ha] = ab }
        }
        let odds = MatchOdds(
            provider: pick.provider?.name ?? "",
            homeTeam: abbrevBySide["home"] ?? "Home",
            awayTeam: abbrevBySide["away"] ?? "Away",
            homeMoneyline: americanOdds(pick.homeTeamOdds?.moneyLine),
            drawMoneyline: americanOdds(pick.drawOdds?.moneyLine),
            awayMoneyline: americanOdds(pick.awayTeamOdds?.moneyLine),
            spread: pick.details ?? "",
            overUnder: pick.overUnder.map(trimmedNumber) ?? ""
        )
        return odds.isEmpty ? nil : odds
    }

    /// Formats a raw moneyline as American odds: positive gets a leading "+",
    /// negative keeps its "-". Empty for a missing or zero line.
    private static func americanOdds(_ value: Double?) -> String {
        guard let value, value != 0 else { return "" }
        let n = Int(value.rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }

    /// Drops a trailing ".0" so "2.5" stays "2.5" but "3.0" reads "3".
    private static func trimmedNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// The two playing teams' display names, from the header, used to flag their
    /// rows in the league table.
    private static func matchTeamNames(from response: SummaryResponse) -> Set<String> {
        let competitors = response.header?.competitions?.first?.competitors ?? []
        return Set(competitors.compactMap { $0.team?.displayName })
    }

    /// Flattens the standings group into ranked rows, flagging the two teams in
    /// the open match. Pulls the pre-formatted W-D-L `overall` record when the
    /// feed carries it, else builds it from wins/ties/losses.
    private static func standings(from response: SummaryResponse) -> [StandingsRow] {
        guard let entries = response.standings?.groups?.first?.standings?.entries else { return [] }
        let highlight = matchTeamNames(from: response)

        return entries.compactMap { entry -> StandingsRow? in
            guard let name = entry.team?.name, !name.isEmpty else { return nil }
            var byName: [String: String] = [:]
            for s in entry.stats ?? [] {
                if let n = s.name { byName[n] = s.displayValue ?? "" }
            }
            let record = byName["overall"].flatMap { $0.isEmpty ? nil : $0 }
                ?? [byName["wins"], byName["ties"], byName["losses"]]
                    .compactMap { $0 }.joined(separator: "-")
            return StandingsRow(
                rank: byName["rank"] ?? "",
                team: name,
                played: byName["gamesPlayed"] ?? "",
                record: record,
                goalDiff: byName["pointDifferential"] ?? "",
                points: byName["points"] ?? "",
                isMatchTeam: highlight.contains(name)
            )
        }
    }

    /// One form strip per side: the last-five outcomes with a tooltip summary.
    private static func form(from teams: [SummaryTeamEvents]?) -> [FormGuide] {
        (teams ?? []).compactMap { t -> FormGuide? in
            let label = t.team?.abbreviation ?? t.team?.displayName ?? ""
            guard !label.isEmpty, let events = t.events, !events.isEmpty else { return nil }
            let results = events.enumerated().map { index, e -> FormResult in
                let outcome = FormResult.Outcome.from(e.gameResult)
                let opp = e.opponent?.abbreviation ?? e.opponent?.displayName ?? ""
                let venue = (e.atVs == "@") ? "@" : "vs"
                var parts: [String] = []
                if let r = e.gameResult, !r.isEmpty { parts.append(r) }
                if let s = e.score, !s.isEmpty { parts.append(s) }
                if !opp.isEmpty { parts.append("\(venue) \(opp)") }
                if let d = e.gameDate.flatMap(parseISODate) { parts.append(shortDate(d)) }
                return FormResult(
                    id: e.id ?? "\(label)-\(index)",
                    outcome: outcome,
                    summary: parts.joined(separator: " ")
                )
            }
            return FormGuide(team: label, results: results)
        }
    }

    /// Previous meetings between the two teams, from the first listed
    /// perspective (the feed mirrors the same fixtures from each side).
    private static func headToHead(from teams: [SummaryTeamEvents]?) -> [HeadToHeadGame] {
        guard let events = teams?.first?.events else { return [] }
        let us = teams?.first?.team?.abbreviation ?? ""
        return events.enumerated().compactMap { index, e -> HeadToHeadGame? in
            let opp = e.opponent?.abbreviation ?? e.opponent?.displayName ?? ""
            guard !opp.isEmpty else { return nil }
            let score = e.score ?? ""
            // Lay the line out home-to-away so the score reads naturally.
            let line: String
            if e.atVs == "@" {
                line = "\(opp) \(score) \(us)"
            } else {
                line = "\(us) \(score) \(opp)"
            }
            let date = e.gameDate.flatMap(parseISODate).map(shortDate) ?? ""
            return HeadToHeadGame(
                id: e.id ?? "\(index)",
                date: date,
                line: line.trimmingCharacters(in: .whitespaces),
                outcome: FormResult.Outcome.from(e.gameResult)
            )
        }
    }

    /// Compact day-month-year, e.g. "14 May 26".
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yy"
        return f
    }()
    private static func shortDate(_ date: Date) -> String { shortDateFormatter.string(from: date) }

    /// Resolves the two boxscore teams into (home, away) via the header's
    /// competitor → team-id map; if the header is absent the feed order
    /// [home, away] is assumed.
    private static func homeAwayTeams(
        from response: SummaryResponse
    ) -> (home: SummaryBoxTeam, away: SummaryBoxTeam)? {
        guard let teams = response.boxscore?.teams, teams.count == 2 else { return nil }
        var sideByID: [String: String] = [:]
        for c in response.header?.competitions?.first?.competitors ?? [] {
            if let id = c.team?.id, let ha = c.homeAway { sideByID[id] = ha }
        }
        func side(_ t: SummaryBoxTeam) -> String? { t.team?.id.flatMap { sideByID[$0] } }
        return (teams.first { side($0) == "home" } ?? teams[0],
                teams.first { side($0) == "away" } ?? teams[1])
    }

    /// Pairs each boxscore statistic with its home/away values.
    private static func teamStats(from response: SummaryResponse) -> [TeamStat] {
        guard let (home, away) = homeAwayTeams(from: response) else { return [] }

        func label(_ s: SummaryStat) -> String? {
            let l = s.label ?? s.name
            return l.map { $0.localizedCapitalized }
        }
        let awayByLabel: [String: String] = Dictionary(
            (away.statistics ?? []).compactMap { s -> (String, String)? in
                guard let l = label(s) else { return nil }
                return (l, s.displayValue ?? "")
            },
            uniquingKeysWith: { first, _ in first }
        )

        return (home.statistics ?? []).compactMap { s in
            guard let l = label(s) else { return nil }
            return TeamStat(label: l, home: s.displayValue ?? "", away: awayByLabel[l] ?? "")
        }
    }

    /// The match's aggregate shooting view: team shot funnel + top shooters.
    /// No xG — the public summary feed doesn't carry it (player or team).
    private static func shots(from response: SummaryResponse) -> ShotData {
        ShotData(
            teamShots: shotTeamStats(from: response),
            shooters: topShooters(from: response)
        )
    }

    /// The team shot funnel — Shots, On Target, Blocked — as home/away
    /// comparison rows, pulled by stat name from the boxscore.
    private static func shotTeamStats(from response: SummaryResponse) -> [TeamStat] {
        guard let (home, away) = homeAwayTeams(from: response) else { return [] }
        func value(_ t: SummaryBoxTeam, _ name: String) -> String? {
            t.statistics?.first { $0.name == name }?.displayValue
        }

        // Funnel order: all shots → on target → blocked.
        let wanted: [(name: String, label: String)] = [
            ("totalShots", "Shots"),
            ("shotsOnTarget", "On Target"),
            ("blockedShots", "Blocked")
        ]
        return wanted.compactMap { w in
            let h = value(home, w.name)
            let a = value(away, w.name)
            guard h != nil || a != nil else { return nil }
            return TeamStat(label: w.label, home: h ?? "0", away: a ?? "0")
        }
    }

    /// Players who took at least one shot, ranked by shot volume (then on-target,
    /// then goals), capped to the top `limit`. Each is tagged with its team's
    /// abbreviation from the header.
    private static func topShooters(from response: SummaryResponse, limit: Int = 10) -> [Shooter] {
        var abbrevBySide: [String: String] = [:]
        for c in response.header?.competitions?.first?.competitors ?? [] {
            if let ha = c.homeAway, let ab = c.team?.abbreviation { abbrevBySide[ha] = ab }
        }

        var shooters: [Shooter] = []
        for roster in response.rosters ?? [] {
            let team = roster.homeAway.flatMap { abbrevBySide[$0] } ?? (roster.homeAway ?? "")
            for (index, p) in (roster.roster ?? []).enumerated() {
                var byName: [String: String] = [:]
                for s in p.stats ?? [] {
                    if let n = s.name { byName[n] = s.displayValue }
                }
                let shots = byName["totalShots"].flatMap { Int($0) } ?? 0
                guard shots > 0 else { continue }
                shooters.append(Shooter(
                    id: p.athlete?.id ?? "\(team)-\(index)",
                    name: p.athlete?.displayName ?? p.athlete?.shortName ?? "—",
                    team: team,
                    shots: shots,
                    onTarget: byName["shotsOnTarget"].flatMap { Int($0) } ?? 0,
                    goals: byName["totalGoals"].flatMap { Int($0) } ?? 0
                ))
            }
        }
        shooters.sort {
            if $0.shots != $1.shots { return $0.shots > $1.shots }
            if $0.onTarget != $1.onTarget { return $0.onTarget > $1.onTarget }
            return $0.goals > $1.goals
        }
        return Array(shooters.prefix(limit))
    }

    private static func lineup(from response: SummaryResponse, side: String) -> Lineup? {
        guard let r = response.rosters?.first(where: { $0.homeAway == side }) else { return nil }
        func player(_ index: Int, _ p: SummaryRosterPlayer) -> LineupPlayer {
            LineupPlayer(
                id: p.athlete?.id ?? "\(side)-\(index)",
                name: p.athlete?.displayName ?? p.athlete?.shortName ?? "—",
                jersey: p.jersey ?? "",
                position: p.position?.abbreviation ?? "",
                subbedIn: p.subbedIn ?? false,
                subbedOut: p.subbedOut ?? false
            )
        }
        let roster = r.roster ?? []
        guard !roster.isEmpty else { return nil }
        let starters = roster.enumerated().filter { $0.element.starter == true }.map { player($0.offset, $0.element) }
        let subs = roster.enumerated().filter { $0.element.starter != true }.map { player($0.offset, $0.element) }
        return Lineup(formation: r.formation ?? "", starters: starters, subs: subs)
    }

    private static func info(from gameInfo: SummaryGameInfo?) -> [InfoItem] {
        guard let gameInfo else { return [] }
        var items: [InfoItem] = []
        if let venue = gameInfo.venue?.fullName, !venue.isEmpty {
            items.append(InfoItem(label: "Venue", value: venue))
        }
        if let attendance = gameInfo.attendance, attendance > 0 {
            items.append(InfoItem(label: "Attendance", value: attendance.formatted()))
        }
        if let ref = gameInfo.officials?.first?.displayName, !ref.isEmpty {
            items.append(InfoItem(label: "Referee", value: ref))
        }
        return items
    }

}
