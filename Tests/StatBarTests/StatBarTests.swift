import XCTest
@testable import StatBar

final class StatBarTests: XCTestCase {
    func testStageLabel() {
        // Regular season (domestic leagues) carries no stage.
        XCTAssertNil(APIService.stageLabel(slug: "regular-season", note: nil))
        XCTAssertNil(APIService.stageLabel(slug: nil, note: nil))
        // Known knockout slugs map to clean labels.
        XCTAssertEqual(APIService.stageLabel(slug: "round-of-16", note: nil), "Round of 16")
        XCTAssertEqual(APIService.stageLabel(slug: "final", note: nil), "Final")
        // Unknown slug falls back to title-case (group-stage → Group Stage).
        XCTAssertEqual(APIService.stageLabel(slug: "group-stage", note: nil), "Group Stage")
        // Leg/round note is appended.
        XCTAssertEqual(APIService.stageLabel(slug: "quarterfinals", note: "1st Leg"),
                       "Quarterfinal · 1st Leg")
        // Note alone (no slug) still surfaces.
        XCTAssertEqual(APIService.stageLabel(slug: nil, note: "1st Leg"), "1st Leg")
    }

    // MARK: - Get Scores intent summary

    @available(macOS 13.0, *)
    func testScoresSummary() {
        func m(_ home: String, _ away: String, _ hs: Int, _ as_: Int, status: String) -> Match {
            Match(sport: .soccer, league: "eng.1", homeTeam: home, awayTeam: away,
                  homeScore: hs, awayScore: as_, status: status, gameClock: "62'",
                  detail: "", downDistance: "", possession: "", fgPct: "",
                  leadingScorer: "", leadingPoints: "", topThree: [], currentLap: "",
                  gapToLeader: "", homeLogo: nil, awayLogo: nil)
        }
        // Live games win and carry the clock.
        let live = GetScoresIntent.summary([m("ARS", "CHE", 2, 1, status: "live")])
        XCTAssertEqual(live, "ARS 2–1 CHE (62')")
        // No live → next fixture surfaced.
        XCTAssertTrue(GetScoresIntent.summary([m("ARS", "CHE", 0, 0, status: "pre")])
            .hasPrefix("Nothing live. Next up:"))
        // No live, no upcoming → latest final.
        XCTAssertTrue(GetScoresIntent.summary([m("ARS", "CHE", 3, 0, status: "final")])
            .contains("full time"))
        // Empty feed.
        XCTAssertEqual(GetScoresIntent.summary([]), "No matches on right now.")
    }

    // MARK: - Followed-team companion

    /// Minimal soccer match; only the fields the companion logic reads matter.
    private func match(_ home: String, _ away: String, status: String,
                       kickoff: Date? = nil, league: String = "esp.1") -> Match {
        Match(sport: .soccer, league: league, homeTeam: home, awayTeam: away,
              homeScore: 0, awayScore: 0, status: status, gameClock: "", detail: "",
              downDistance: "", possession: "", fgPct: "", leadingScorer: "",
              leadingPoints: "", topThree: [], currentLap: "", gapToLeader: "",
              homeLogo: nil, awayLogo: nil, kickoff: kickoff)
    }

    func testCompanion() {
        let now = Date()
        let grace: TimeInterval = 600
        let barca = Team(sport: .soccer, name: "Barcelona")

        // No followed team's match present → nil (caller falls back to Smart Focus).
        XCTAssertNil(MatchFocus.companion(forFollowed: [barca],
            in: [match("Madrid", "Atletico", status: "live")],
            firstSeenFinal: [:], now: now, graceWindow: grace))

        // Live followed match wins over its own upcoming fixture.
        let live = match("Barcelona", "Getafe", status: "live")
        let upcoming = match("Sevilla", "Barcelona", status: "pre",
                             kickoff: now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(MatchFocus.companion(forFollowed: [barca],
            in: [upcoming, live], firstSeenFinal: [:], now: now, graceWindow: grace)?.matchID,
            live.matchID)

        // Final inside the grace window shows (catch the score); past it, advance
        // to the next fixture.
        let fin = match("Barcelona", "Valencia", status: "final")
        let seenRecently = [fin.matchID: now.addingTimeInterval(-60)]      // 1 min ago
        XCTAssertEqual(MatchFocus.companion(forFollowed: [barca],
            in: [fin, upcoming], firstSeenFinal: seenRecently, now: now, graceWindow: grace)?.matchID,
            fin.matchID)
        let seenOld = [fin.matchID: now.addingTimeInterval(-3600)]         // 1 hr ago
        XCTAssertEqual(MatchFocus.companion(forFollowed: [barca],
            in: [fin, upcoming], firstSeenFinal: seenOld, now: now, graceWindow: grace)?.matchID,
            upcoming.matchID)

        // Only an upcoming fixture → that fixture; soonest wins among several.
        let soon = match("Barcelona", "Cadiz", status: "pre", kickoff: now.addingTimeInterval(86400))
        let later = match("Barcelona", "Betis", status: "pre", kickoff: now.addingTimeInterval(5 * 86400))
        XCTAssertEqual(MatchFocus.companion(forFollowed: [barca],
            in: [later, soon], firstSeenFinal: [:], now: now, graceWindow: grace)?.matchID,
            soon.matchID)
    }
}
