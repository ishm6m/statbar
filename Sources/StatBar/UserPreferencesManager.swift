import Foundation

@MainActor
final class UserPreferencesManager {
    static let shared = UserPreferencesManager()

    private let defaults = UserDefaults.standard

    private let sportOrderKey = "StatBarSportOrder"
    private let enabledSportsKey = "StatBarEnabledSports"   // legacy — read once to migrate
    private let enabledLeaguesKey = "StatBarEnabledLeagues"
    private let displayModeKey = "StatBarDisplayMode"
    private let followedTeamsKey = "StatBarFollowedTeams"
    private let notifyMatchStartingKey = "StatBarNotifyMatchStarting"
    private let notifyFinalScoreKey = "StatBarNotifyFinalScore"
    private let notifyGoalsKey = "StatBarNotifyGoals"
    private let onboardingCompletedKey = "StatBarOnboardingCompleted"
    private let autoFocusEnabledKey = "StatBarAutoFocusEnabled"
    private let manualFocusMatchIDKey = "StatBarManualFocusMatchID"
    private let refreshSpeedKey = "StatBarRefreshSpeed"
    private let largeTextKey = "StatBarLargeText"
    private let interestScoresKey = "StatBarInterestScores"

    static let maxFollowedTeams = 10

    private init() {}

    // MARK: - Sports (ordered + enabled)

    /// Full ordered list of every sport. Order = menu bar priority.
    var sportOrder: [Sport] {
        get {
            guard let raw = defaults.array(forKey: sportOrderKey) as? [String] else {
                return Sport.allCases
            }
            let decoded = raw.compactMap { Sport(rawValue: $0) }
            // Append any sport added since the order was saved.
            let missing = Sport.allCases.filter { !decoded.contains($0) }
            return decoded + missing
        }
        set {
            defaults.set(newValue.map { $0.rawValue }, forKey: sportOrderKey)
        }
    }

    /// Enabled leagues, by id (e.g. "eng.1", "uefa.champions"). The polling/
    /// enabling unit. StatBar is soccer-only, so fresh installs default to the
    /// marquee competitions; onboarding lets the user add the rest. Any legacy
    /// non-soccer enable set no longer intersects the catalog and falls back to
    /// this default.
    static let defaultLeagues: Set<String> = ["eng.1", "esp.1", "uefa.champions"]

    var enabledLeagues: Set<String> {
        get {
            if let raw = defaults.array(forKey: enabledLeaguesKey) as? [String] {
                let kept = Set(raw).intersection(Set(LeagueCatalog.all.map(\.id)))
                return kept.isEmpty ? Self.defaultLeagues : kept
            }
            // Migrate any legacy enabledSports set; non-soccer ids drop out.
            if let legacy = defaults.array(forKey: enabledSportsKey) as? [String] {
                let supported = Set(LeagueCatalog.all.map(\.id))
                let migrated = Set(legacy).intersection(supported)
                return migrated.isEmpty ? Self.defaultLeagues : migrated
            }
            return Self.defaultLeagues
        }
        set {
            defaults.set(Array(newValue), forKey: enabledLeaguesKey)
        }
    }

    /// Enabled, supported leagues in priority order: sport-category order first
    /// (`sportOrder`), then catalog order within a sport. What the menu bar,
    /// popup, and the fetch pipeline iterate.
    var activeLeagues: [LeagueDefinition] {
        let enabled = enabledLeagues
        let sportRank = Dictionary(uniqueKeysWithValues: sportOrder.enumerated().map { ($1, $0) })
        return LeagueCatalog.all
            .filter { enabled.contains($0.id) }
            .enumerated()
            .sorted { lhs, rhs in
                let lr = sportRank[lhs.element.sport] ?? Int.max
                let rr = sportRank[rhs.element.sport] ?? Int.max
                if lr != rr { return lr < rr }
                return lhs.offset < rhs.offset // catalog order within a sport
            }
            .map(\.element)
    }

    func toggleLeague(_ id: String) {
        var enabled = enabledLeagues
        if enabled.contains(id) {
            enabled.remove(id)
        } else {
            // Unknown ids have no feed — refuse to enable.
            guard LeagueCatalog.byID(id) != nil else { return }
            enabled.insert(id)
        }
        enabledLeagues = enabled
    }

    // MARK: - Display

    var displayMode: DisplayMode {
        get {
            guard let raw = defaults.string(forKey: displayModeKey),
                  let mode = DisplayMode(rawValue: raw) else {
                return .teamScore
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: displayModeKey)
        }
    }

    // MARK: - Followed teams (max 10)

    var followedTeams: [Team] {
        get {
            guard let data = defaults.data(forKey: followedTeamsKey),
                  let decoded = try? JSONDecoder().decode([Team].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            let capped = Array(newValue.prefix(Self.maxFollowedTeams))
            if let encoded = try? JSONEncoder().encode(capped) {
                defaults.set(encoded, forKey: followedTeamsKey)
            }
        }
    }

    func isFollowing(_ team: Team) -> Bool {
        followedTeams.contains(team)
    }

    /// Adds a team if there is room. Returns false when already at the cap.
    @discardableResult
    func addTeam(_ team: Team) -> Bool {
        var teams = followedTeams
        guard !teams.contains(team) else { return true }
        guard teams.count < Self.maxFollowedTeams else { return false }
        teams.append(team)
        followedTeams = teams
        return true
    }

    func removeTeam(_ team: Team) {
        followedTeams = followedTeams.filter { $0 != team }
    }

    // MARK: - Notifications

    var notifyMatchStarting: Bool {
        get { defaults.object(forKey: notifyMatchStartingKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: notifyMatchStartingKey) }
    }

    /// Final score notifications default ON.
    var notifyFinalScore: Bool {
        get { defaults.object(forKey: notifyFinalScoreKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: notifyFinalScoreKey) }
    }

    var notifyGoals: Bool {
        get { defaults.object(forKey: notifyGoalsKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: notifyGoalsKey) }
    }

    // MARK: - Onboarding

    /// True once the first-run onboarding flow has been completed (or skipped).
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: onboardingCompletedKey) }
        set { defaults.set(newValue, forKey: onboardingCompletedKey) }
    }

    // MARK: - Refresh cadence

    /// How aggressively the score loop polls. Defaults to `.normal` (the legacy
    /// 25s live / 10m idle cadence) so behavior is unchanged until the user opts
    /// into Fast or Battery Saver. Read live by `DataRefreshManager` each cycle.
    var refreshSpeed: RefreshSpeed {
        get {
            guard let raw = defaults.string(forKey: refreshSpeedKey),
                  let speed = RefreshSpeed(rawValue: raw) else {
                return .normal
            }
            return speed
        }
        set { defaults.set(newValue.rawValue, forKey: refreshSpeedKey) }
    }

    // MARK: - Accessibility

    /// When true, the popup and Settings render larger text for legibility —
    /// scales the score/team readouts and all semantic-font chrome via an
    /// injected `dynamicTypeSize`. Off by default (the dense default layout).
    var largeText: Bool {
        get { defaults.bool(forKey: largeTextKey) }
        set { defaults.set(newValue, forKey: largeTextKey) }
    }

    // MARK: - Learned interest (Smart Focus personalization)

    /// Running count of how often the user opens detail / a team page, keyed by
    /// team token (lowercased abbreviation, as the feed spells it) and league id.
    /// Feeds `MatchFocus.interestBonus` so leagues and teams you actually engage
    /// with drift up the ranking. A plain `[String: Int]` in UserDefaults — small
    /// (≤ a few dozen keys), and a wrong/stale count only nudges ordering.
    var interestScores: [String: Int] {
        (defaults.dictionary(forKey: interestScoresKey) as? [String: Int]) ?? [:]
    }

    /// Bumps the interest counts for a match's two teams and its league — called
    /// when the user drills into that game or opens one of its teams.
    func recordInterest(in match: Match) {
        var scores = interestScores
        for key in [match.homeTeam.lowercased(), match.awayTeam.lowercased(), match.league] {
            scores[key, default: 0] += 1
        }
        defaults.set(scores, forKey: interestScoresKey)
    }

    // MARK: - Smart Focus

    /// When true (default), the menu bar and popup auto-pick the most relevant
    /// match. When false, the user's manually selected game is preserved.
    var autoFocusEnabled: Bool {
        get { defaults.object(forKey: autoFocusEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoFocusEnabledKey) }
    }

    /// The match the user manually pinned as the focus, used only while
    /// `autoFocusEnabled` is false. Nil falls back to Smart Focus ordering.
    var manualFocusMatchID: String? {
        get { defaults.string(forKey: manualFocusMatchIDKey) }
        set { defaults.set(newValue, forKey: manualFocusMatchIDKey) }
    }
}
