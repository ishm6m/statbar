import Foundation

/// User-selectable poll cadence for the score refresh loop. Replaces the
/// previously hard-coded `DataRefreshManager` intervals so the user can trade
/// freshness against battery/network use. Each preset carries both a live
/// interval (a game is in progress) and an idle interval (nothing live); the
/// geometric failure backoff in `DataRefreshManager` still applies on top.
enum RefreshSpeed: String, CaseIterable, Identifiable, Sendable {
    /// Snappiest — for following a tight finish. More requests.
    case fast
    /// Balanced default (matches the legacy 25s live / 10m idle cadence).
    case normal
    /// Fewest requests — easiest on battery on the move.
    case batterySaver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .batterySaver: return "Battery Saver"
        }
    }

    /// Poll interval while at least one match is live.
    var liveInterval: TimeInterval {
        switch self {
        case .fast: return 15
        case .normal: return 25
        case .batterySaver: return 60
        }
    }

    /// Tighter cadence when a live game is "clutch" — close margin or overtime
    /// (`MatchFocus.isClutch`). Floored so even the snappiest preset stays a
    /// polite distance from ESPN's feed. Battery Saver still tightens, but less.
    var clutchInterval: TimeInterval {
        switch self {
        case .fast: return 8
        case .normal: return 12
        case .batterySaver: return 30
        }
    }

    /// Poll interval when nothing is live (schedules / finals only).
    var idleInterval: TimeInterval {
        switch self {
        case .fast: return 300
        case .normal: return 600
        case .batterySaver: return 1800
        }
    }

    /// One-line summary for the Settings row.
    var subtitle: String {
        let live = Int(liveInterval)
        let idleMin = Int(idleInterval / 60)
        return "\(live)s live · \(idleMin)m idle"
    }
}
