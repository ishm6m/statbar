import Foundation

/// Suppresses duplicate notifications across polling cycles and app restarts
/// (PRD v1.0 §2).
///
/// The score feed is snapshot-only, so the same event can be re-derived on
/// consecutive refreshes (and a restart loses the in-memory baseline entirely).
/// Each event gets a *deterministic* id from its meaningful state — e.g. a
/// scoreline of 21-17 yields one id, 21-24 yields another — so re-deriving the
/// same event produces the same id and is dropped. Sent ids are persisted with
/// a timestamp and pruned after `ttl`, so the dedup set survives restarts
/// without growing unbounded.
@MainActor
final class NotificationDeduplicator {
    private let defaults = UserDefaults.standard
    private let storeKey = "StatBarSentNotificationIDs"
    private let ttl: TimeInterval

    /// `ttl` of 6h covers a game-day's worth of restarts without leaking ids.
    init(ttl: TimeInterval = 6 * 60 * 60) {
        self.ttl = ttl
        prune()
    }

    /// Deterministic id for an event. `state` carries the bits that make the
    /// event distinct (scoreline, leader, …) so a genuinely new event gets a
    /// new id while a re-derived one collides and is suppressed.
    static func eventID(matchID: String, type: String, state: String = "") -> String {
        "\(matchID)|\(type)|\(state)"
    }

    /// Returns true the first time an id is seen, false on every repeat.
    /// Records the id (with now() timestamp) when it returns true.
    func shouldSend(_ id: String) -> Bool {
        var store = load()
        if let sentAt = store[id], Date().timeIntervalSince(sentAt) < ttl {
            return false
        }
        store[id] = Date()
        save(store)
        return true
    }

    // MARK: - Persistence

    private func load() -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: storeKey) as? [String: Date] else {
            return [:]
        }
        return raw
    }

    private func save(_ store: [String: Date]) {
        defaults.set(store, forKey: storeKey)
    }

    private func prune() {
        let now = Date()
        let kept = load().filter { now.timeIntervalSince($0.value) < ttl }
        save(kept)
    }
}
