import Foundation

/// A followable team. Stored in UserDefaults as part of the followed-teams list.
///
/// Carries enough metadata to render a real logo whenever one can be resolved:
/// a stable `id`, a display `name`, a short `abbreviation` (ESPN team code for
/// sports with CDN coverage), the `sport`/league it belongs to, and an optional
/// `logoURLOverride` for teams whose artwork lives at a non-derivable URL
/// (e.g. ESPN's numeric soccer IDs). When no logo resolves, the UI falls back to
/// a monogram avatar derived from `name`.
struct Team: Codable, Hashable, Identifiable {
    let sport: Sport
    let name: String
    /// Short code used to resolve the logo (ESPN team abbreviation for NFL/NBA/
    /// NHL) and as a compact label. Always present — derived from `name` when not
    /// supplied explicitly.
    let abbreviation: String
    /// Explicit logo URL, used in preference to the derived ESPN URL when set.
    let logoURLOverride: String?

    /// Stable identifier used for persistence and de-duplication. Intentionally
    /// independent of the metadata fields so they can change without breaking
    /// stored follows.
    var id: String { "\(sport.rawValue):\(name)" }

    var label: String { "\(sport.emoji) \(name)" }

    init(sport: Sport, name: String, abbreviation: String? = nil, logoURLOverride: String? = nil) {
        self.sport = sport
        self.name = name
        self.abbreviation = abbreviation ?? Team.defaultAbbreviation(for: name)
        self.logoURLOverride = logoURLOverride
    }

    // Backward-compatible decode: teams stored before metadata existed only have
    // `sport` and `name`; fill the rest with sensible defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sport = try c.decode(Sport.self, forKey: .sport)
        let name = try c.decode(String.self, forKey: .name)
        self.sport = sport
        self.name = name
        self.abbreviation = try c.decodeIfPresent(String.self, forKey: .abbreviation)
            ?? Team.defaultAbbreviation(for: name)
        self.logoURLOverride = try c.decodeIfPresent(String.self, forKey: .logoURLOverride)
    }

    // Identity is the stable id only — metadata differences never split a team
    // (so a freshly catalogued team still matches one persisted without metadata).
    static func == (lhs: Team, rhs: Team) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Fallback abbreviation when none is supplied: the name's monogram.
    static func defaultAbbreviation(for name: String) -> String {
        logoMonogram(from: name)
    }
}

/// Built-in searchable list of well-known teams per sport.
/// Live team rosters come from the APIs at runtime; this catalog backs the
/// Settings search field so users can follow teams before any match is loaded.
enum TeamCatalog {
    static let all: [Team] = {
        var teams: [Team] = []
        for (sport, entries) in catalog {
            teams.append(contentsOf: entries.map {
                Team(sport: sport, name: $0.name, abbreviation: $0.abbreviation, logoURLOverride: $0.logoURL)
            })
        }
        return teams.sorted { $0.name < $1.name }
    }()

    static func search(_ query: String) -> [Team] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.abbreviation.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// One catalog entry before it becomes a `Team`. `abbreviation` is the ESPN
    /// team code where the CDN has coverage; `logoURL` overrides the derived URL
    /// for sources keyed by something other than the abbreviation.
    private struct Entry {
        let name: String
        let abbreviation: String?
        let logoURL: String?
        init(_ name: String, _ abbreviation: String? = nil, logoURL: String? = nil) {
            self.name = name
            self.abbreviation = abbreviation
            self.logoURL = logoURL
        }

        static func soccer(_ name: String, _ abbreviation: String, espnID: Int) -> Entry {
            Entry(name, abbreviation,
                  logoURL: "https://a.espncdn.com/i/teamlogos/soccer/500/\(espnID).png")
        }
    }

    private static let catalog: [Sport: [Entry]] = [
        .soccer: [
            // ESPN keys soccer logos by numeric team ID, not abbreviation, so
            // these carry an explicit override URL.
            Entry.soccer("Arsenal", "ARS", espnID: 359),
            Entry.soccer("Manchester City", "MNC", espnID: 382),
            Entry.soccer("Manchester United", "MAN", espnID: 360),
            Entry.soccer("Liverpool", "LIV", espnID: 364),
            Entry.soccer("Tottenham Hotspur", "TOT", espnID: 367),
            Entry.soccer("Chelsea", "CHE", espnID: 363),
            Entry.soccer("Real Madrid", "RMA", espnID: 86),
            Entry.soccer("Barcelona", "BAR", espnID: 83),
            Entry.soccer("Atletico Madrid", "ATM", espnID: 1068),
            Entry.soccer("Bayern Munich", "BAY", espnID: 132),
            Entry.soccer("Borussia Dortmund", "DOR", espnID: 124),
            Entry.soccer("Juventus", "JUV", espnID: 111),
            Entry.soccer("Inter Milan", "INT", espnID: 110),
            Entry.soccer("AC Milan", "MIL", espnID: 103),
            Entry.soccer("Paris Saint-Germain", "PSG", espnID: 160),
            Entry.soccer("Inter Miami", "MIA", espnID: 20232),
            Entry.soccer("LA Galaxy", "LAG", espnID: 187),
        ],
    ]
}
