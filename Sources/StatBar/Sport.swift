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

    /// Calendar months (1–12) this sport is typically in season. Soccer spans the
    /// globe (some league is always running), so it's year-round.
    var inSeasonMonths: Set<Int> {
        switch self {
        case .soccer: return Set(1...12)
        }
    }

    /// Whether this sport is likely playing on `date` (default: now).
    func isInSeason(on date: Date = Date()) -> Bool {
        inSeasonMonths.contains(Calendar.current.component(.month, from: date))
    }

}
