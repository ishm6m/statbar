import Foundation
import AppKit
import UserNotifications

/// Collects runtime diagnostics for the hidden Debug Information panel
/// and feeds startup-time logging.
///
/// Single main-actor store; the refresh loop records the last successful
/// refresh and its latency here, and the Settings panel reads the snapshot.
/// Formatters are created once and reused — never per render.
@MainActor
final class DiagnosticsStore: ObservableObject {
    static let shared = DiagnosticsStore()

    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastLatencyMS: Int?
    @Published private(set) var launchDurationMS: Int?
    @Published private(set) var notificationAuth: String = "Unknown"
    @Published private(set) var lastUpdateCheck: Date?
    @Published private(set) var lastUpdateResult: String = "Never checked"

    /// Reused formatter — building `DateFormatter` per call is a known hotspot.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private init() {}

    // MARK: - Recording

    func recordRefresh(latency: TimeInterval, at date: Date = Date()) {
        lastRefresh = date
        lastLatencyMS = Int((latency * 1000).rounded())
    }

    func recordLaunchDuration(_ seconds: TimeInterval) {
        launchDurationMS = Int((seconds * 1000).rounded())
    }

    /// Records the outcome of the most recent update check, surfaced in the
    /// hidden Debug Information panel.
    func recordUpdateCheck(result: String, at date: Date = Date()) {
        lastUpdateCheck = date
        lastUpdateResult = result
    }

    func refreshNotificationAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: String
            switch settings.authorizationStatus {
            case .authorized: status = "Authorized"
            case .denied: status = "Denied"
            case .notDetermined: status = "Not determined"
            case .provisional: status = "Provisional"
            case .ephemeral: status = "Ephemeral"
            @unknown default: status = "Unknown"
            }
            Task { @MainActor in self.notificationAuth = status }
        }
    }

    // MARK: - Static facts (read on demand)

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The endpoint the update checker reads.
    var updateURL: String {
        Config.Updates.versionManifestURL.absoluteString
    }

    var lastUpdateCheckText: String {
        guard let lastUpdateCheck else { return "Never" }
        return Self.timeFormatter.string(from: lastUpdateCheck)
    }

    var lastRefreshText: String {
        guard let lastRefresh else { return "Never" }
        return Self.timeFormatter.string(from: lastRefresh)
    }

    var latencyText: String {
        guard let lastLatencyMS else { return "—" }
        return "\(lastLatencyMS) ms"
    }

    var launchDurationText: String {
        guard let launchDurationMS else { return "—" }
        return "\(launchDurationMS) ms"
    }
}
