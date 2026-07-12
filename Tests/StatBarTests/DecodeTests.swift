import XCTest
@testable import StatBar

/// Decode-layer tests against real ESPN payloads (trimmed captures committed
/// under Fixtures/). The decode layer is the app's most fragile surface — ESPN
/// shifts its schema without notice — so these pin today's shape and the
/// defensive fallbacks for tomorrow's.
final class DecodeTests: XCTestCase {
    private let premierLeague = LeagueDefinition(
        id: "eng.1", sport: .soccer, displayName: "Premier League"
    )

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Scoreboard

    /// Real Premier League scoreboard (final matchday 2025-26): every field the
    /// popup renders decodes to what ESPN sent.
    func testDecodeScoreboard() throws {
        let matches = try APIService.shared.decodeESPNMatches(
            from: fixture("scoreboard-eng1"), league: premierLeague
        )
        XCTAssertEqual(matches.count, 6)

        let first = try XCTUnwrap(matches.first)
        XCTAssertEqual(first.league, "eng.1")
        XCTAssertEqual(first.sport, .soccer)
        XCTAssertEqual(first.homeTeam, "MAN")
        XCTAssertEqual(first.awayTeam, "NFO")
        XCTAssertEqual(first.homeScore, 3)
        XCTAssertEqual(first.awayScore, 2)
        XCTAssertEqual(first.status, "final")
        XCTAssertTrue(first.isFinal)
        XCTAssertEqual(first.espnEventID, "740963")
        XCTAssertEqual(first.homeTeamID, "360")
        XCTAssertEqual(first.awayTeamID, "393")
        XCTAssertNotNil(first.homeLogo)
        XCTAssertNotNil(first.awayLogo)
        XCTAssertEqual(first.homeColor, "da020e")
        XCTAssertEqual(first.kickoff, APIService.parseISODate("2026-05-17T11:30Z"))
        XCTAssertNotNil(first.gameURL)
        // Domestic league: the season-name slug must not leak in as a stage.
        XCTAssertNil(first.stage)
    }

    /// Real Champions League semifinal: knockout stage + leg note surface.
    func testDecodeScoreboardKnockout() throws {
        let ucl = LeagueDefinition(
            id: "uefa.champions", sport: .soccer, displayName: "Champions League"
        )
        let matches = try APIService.shared.decodeESPNMatches(
            from: fixture("scoreboard-ucl-semifinal"), league: ucl
        )
        XCTAssertEqual(matches.count, 1)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.homeTeam, "ARS")
        XCTAssertEqual(match.awayTeam, "ATM")
        XCTAssertEqual(match.stage, "Semifinal · 2nd Leg - Arsenal advance 2-1 on aggregate")
    }

    /// Schema drift: an event stripped to the bare minimum (no ids, dates,
    /// links, season, scores, logos, colors) still decodes; optionals go nil
    /// and scores default to 0 rather than dropping the row.
    func testDecodeScoreboardMinimalEvent() throws {
        let minimal = """
        {"events":[{"competitions":[{"competitors":[
            {"homeAway":"home","team":{"abbreviation":"AAA","displayName":"Alpha"}},
            {"homeAway":"away","team":{"abbreviation":"BBB","displayName":"Beta"}}
        ]}],"status":{"type":{"state":"in"}}}]}
        """
        let matches = try APIService.shared.decodeESPNMatches(
            from: Data(minimal.utf8), league: premierLeague
        )
        XCTAssertEqual(matches.count, 1)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.status, "live")
        XCTAssertEqual(match.homeScore, 0)
        XCTAssertEqual(match.awayScore, 0)
        XCTAssertNil(match.espnEventID)
        XCTAssertNil(match.kickoff)
        XCTAssertNil(match.gameURL)
        XCTAssertNil(match.homeLogo)
        XCTAssertNil(match.stage)
    }

    /// An event missing one side is dropped; the rest of the feed survives.
    func testDecodeScoreboardDropsOneSidedEvent() throws {
        let lopsided = """
        {"events":[{"competitions":[{"competitors":[
            {"homeAway":"home","team":{"abbreviation":"AAA","displayName":"Alpha"}}
        ]}],"status":{"type":{"state":"pre"}}}]}
        """
        let matches = try APIService.shared.decodeESPNMatches(
            from: Data(lopsided.utf8), league: premierLeague
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testDecodeScoreboardMalformed() {
        XCTAssertThrowsError(try APIService.shared.decodeESPNMatches(
            from: Data("not json".utf8), league: premierLeague
        ))
        XCTAssertThrowsError(try APIService.shared.decodeESPNMatches(
            from: Data("{\"unexpected\":true}".utf8), league: premierLeague
        ))
    }

    /// A cached `[Match]` blob round-trips losslessly through the synthesized
    /// Codable conformance (guards the stale-while-revalidate cache path).
    func testMatchCacheRoundTrip() throws {
        let matches = try APIService.shared.decodeESPNMatches(
            from: fixture("scoreboard-eng1"), league: premierLeague
        )
        let data = try JSONEncoder().encode(matches)
        let decoded = try JSONDecoder().decode([Match].self, from: data)
        XCTAssertEqual(decoded, matches)
    }

    // MARK: - Match summary (detail view)

    /// Real summary payload (Man United 3-2 Forest): every detail tab decodes.
    func testDecodeMatchDetail() throws {
        let detail = APIService.shared.decodeMatchDetail(
            from: try fixture("summary-eng1"), matchID: "eng.1-man-nfo"
        )
        XCTAssertEqual(detail.matchID, "eng.1-man-nfo")
        XCTAssertFalse(detail.isEmpty)

        // Timeline: newest-first, goals detected, 5 goals in this match.
        XCTAssertEqual(detail.events.count, 20)
        XCTAssertEqual(detail.events.filter { $0.kind == .goal }.count, 5)
        XCTAssertFalse(detail.commentary.isEmpty)

        // Stats resolved to the correct sides via the header competitor map.
        XCTAssertFalse(detail.teamStats.isEmpty)
        let shots = detail.shots.teamShots.map(\.label)
        XCTAssertEqual(shots, ["Shots", "On Target", "Blocked"])
        XCTAssertFalse(detail.shots.shooters.isEmpty)

        // Standings: full 20-team table with both playing teams flagged.
        XCTAssertEqual(detail.standings.count, 20)
        XCTAssertEqual(detail.standings.filter(\.isMatchTeam).count, 2)

        XCTAssertTrue(detail.info.contains { $0.value == "Old Trafford" })
        XCTAssertEqual(detail.form.count, 2)
        XCTAssertFalse(detail.headToHead.isEmpty)
        XCTAssertEqual(detail.odds?.provider, "DraftKings")
    }

    /// Malformed summary degrades to the empty detail (drives the empty state)
    /// instead of crashing or throwing into the UI.
    func testDecodeMatchDetailMalformed() {
        let detail = APIService.shared.decodeMatchDetail(
            from: Data("<html>gateway error</html>".utf8), matchID: "x"
        )
        XCTAssertEqual(detail.matchID, "x")
        XCTAssertTrue(detail.isEmpty)
    }

    // MARK: - Stage label season-name suppression

    /// Domestic feeds put the season *name* in the per-event slug; a year in
    /// the slug must read as regular season, not a stage.
    func testStageLabelIgnoresSeasonNameSlugs() {
        XCTAssertNil(APIService.stageLabel(slug: "2025-26-english-premier-league", note: nil))
        XCTAssertNil(APIService.stageLabel(slug: "2026-brasileiro-serie-a", note: nil))
        // A genuine phase without a year still surfaces.
        XCTAssertEqual(APIService.stageLabel(slug: "torneo-apertura", note: nil), "Torneo Apertura")
    }
}
