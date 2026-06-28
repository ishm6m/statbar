import Foundation

/// Analytics is currently disabled. The PostHog SDK was removed — it shipped
/// behind a placeholder project key, so `isConfigured` was always false and the
/// SDK never initialized or sent anything. These no-op entry points stay so the
/// call sites throughout the app are untouched; to re-enable analytics, wire a
/// provider into `capture` here (and re-add its dependency) without touching any
/// caller. Privacy contract to preserve if re-enabled (PRD §3): anonymous id
/// only, never team names or scores, client IP stripped.
@MainActor
enum AnalyticsService {
    static func bootstrap() {}
    static func appLaunched() {}
    static func sportToggled(_ sport: Sport, enabled on: Bool) {}
    static func displayModeChanged(_ mode: DisplayMode) {}
    static func notificationSent(type: String, sport: Sport) {}
    static func favouriteTeamAdded(sport: Sport) {}
    static func onboardingCompleted(sportCount: Int, teamCount: Int, notificationsEnabled: Bool) {}
    static func autoFocusToggled(_ enabled: Bool) {}
}
