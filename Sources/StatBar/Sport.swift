import Foundation

/// The sport category a league belongs to. StatBar is soccer-only, so this is a
/// single-case enum today — it still exists as the type that supplies the emoji,
/// Smart Focus thresholds, and UI grouping, and keeps `Match`/`Team`/prefs
/// Codable shapes stable. Adding a sport family later means adding a case here
/// (emoji + thresholds) and listing its leagues in `LeagueCatalog`.
enum Sport: String, CaseIterable, Codable {
    case soccer

    /// Family name shown as a section header / filter chip.
    var displayName: String {
        switch self {
        case .soccer: return "Soccer"
        }
    }

    var emoji: String {
        switch self {
        case .soccer: return "⚽"
        }
    }
}
