import Foundation

/// One league StatBar can poll. The catalog (`LeagueCatalog`) is the single
/// source of truth for what gets fetched: a league is the unit users enable and
/// the unit the generic ESPN pipeline iterates. `sport` is the broader category
/// it belongs to (drives emoji, Smart Focus thresholds, popup tabs, and UI
/// section headers) — so a league carries both its own identity and its family.
///
/// ESPN's scoreboard endpoint is addressed by two path segments,
/// `sports/{espnSportSlug}/{id}/scoreboard`, which is all the routing the
/// provider needs. Adding a league that shares ESPN's uniform scoreboard
/// schema is therefore a one-line catalog change, not new code.
struct LeagueDefinition: Identifiable, Hashable, Sendable {
    /// ESPN path segment for the sport family. StatBar is soccer-only, so every
    /// league shares this — one constant rather than a per-row column.
    static let espnSportSlug = "soccer"

    /// ESPN league slug ("eng.1", "uefa.champions", …), doubling as the stable
    /// id for persistence, cache keys, and `Match.league`.
    let id: String
    /// Sport category — supplies emoji, focus thresholds, and UI grouping.
    let sport: Sport
    /// User-facing name ("Premier League").
    let displayName: String
}
