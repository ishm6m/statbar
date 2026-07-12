import Foundation

/// The dynamic league catalog. Adding a league that shares ESPN's scoreboard
/// schema (team sports with home/away competitors + scores) is a single line
/// here — no networking code changes. Organized by sport so it scales to many
/// leagues; extending to a new sport family means adding one `Sport` case
/// (emoji + Smart Focus thresholds) and then listing its leagues below.
///
/// Only team sports appear here. Non-team formats (motor racing, tennis, golf,
/// individual combat) don't map onto the home/away-score schema and stay out of
/// the catalog until a dedicated provider exists, so they never surface a
/// control that can't fetch.
enum LeagueCatalog {
    static let all: [LeagueDefinition] = [
        LeagueDefinition(id: "eng.1", sport: .soccer, displayName: "Premier League"),
        LeagueDefinition(id: "esp.1", sport: .soccer, displayName: "La Liga"),
        LeagueDefinition(id: "ita.1", sport: .soccer, displayName: "Serie A"),
        LeagueDefinition(id: "ger.1", sport: .soccer, displayName: "Bundesliga"),
        LeagueDefinition(id: "fra.1", sport: .soccer, displayName: "Ligue 1"),
        LeagueDefinition(id: "usa.1", sport: .soccer, displayName: "MLS"),
        LeagueDefinition(id: "eng.2", sport: .soccer, displayName: "EFL Championship"),
        LeagueDefinition(id: "por.1", sport: .soccer, displayName: "Primeira Liga"),
        LeagueDefinition(id: "ned.1", sport: .soccer, displayName: "Eredivisie"),
        LeagueDefinition(id: "mex.1", sport: .soccer, displayName: "Liga MX"),
        LeagueDefinition(id: "bra.1", sport: .soccer, displayName: "Brasileirão"),
        LeagueDefinition(id: "usa.nwsl", sport: .soccer, displayName: "NWSL"),
        LeagueDefinition(id: "uefa.champions", sport: .soccer, displayName: "Champions League"),
        LeagueDefinition(id: "uefa.europa", sport: .soccer, displayName: "Europa League"),
        LeagueDefinition(id: "uefa.europa.conf", sport: .soccer, displayName: "Conference League"),
        LeagueDefinition(id: "fifa.world", sport: .soccer, displayName: "FIFA World Cup"),
        LeagueDefinition(id: "fifa.wwc", sport: .soccer, displayName: "FIFA Women's World Cup"),
    ]

    /// Default league pre-selected during onboarding when the user picks none.
    static let defaultLeagueID = "eng.1"

    private static let byIDIndex: [String: LeagueDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    /// Look up a league by its stable id (e.g. from `Match.league` or prefs).
    static func byID(_ id: String) -> LeagueDefinition? { byIDIndex[id] }

    /// Leagues belonging to a sport category, in catalog order. Used by
    /// onboarding/settings to render one section per sport.
    static func leagues(for sport: Sport) -> [LeagueDefinition] {
        all.filter { $0.sport == sport }
    }

    /// Sport categories that have at least one league, in the order their first
    /// league appears in the catalog. Drives UI section ordering.
    static let supportedSports: [Sport] = {
        var seen = Set<Sport>()
        var order: [Sport] = []
        for league in all where seen.insert(league.sport).inserted {
            order.append(league.sport)
        }
        return order
    }()
}
