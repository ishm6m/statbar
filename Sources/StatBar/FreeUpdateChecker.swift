import AppKit
import Foundation

/// Lightweight, dependency-free update checker.
///
/// The default update mechanism (see `Config.Updates.useSparkle`). It fetches a
/// small `version.json` manifest from a configurable URL
/// (`Config.Updates.versionManifestURL`), compares the latest version against
/// the installed `CFBundleShortVersionString`, and presents a native `NSAlert`.
///
/// Expected manifest shape (only `version` required):
/// ```json
/// {
///   "version": "1.2.0",
///   "downloadURL": "https://github.com/ishm6m/statbar/releases/latest",
///   "releaseNotes": "• Fixed NHL scores\n• Faster launch",
///   "minimumSupported": "1.1.0",
///   "publishedAt": "2026-06-17T12:00:00Z"
/// }
/// ```
/// `minimumSupported`: if the installed version is older, the update is flagged
/// as required. `publishedAt`: ISO-8601 timestamp, shown in the alert.
@MainActor
final class FreeUpdateChecker {
    static let shared = FreeUpdateChecker()

    private let manifestURL: URL
    private let session: URLSession

    init(manifestURL: URL = Config.Updates.versionManifestURL,
         session: URLSession = .shared) {
        self.manifestURL = manifestURL
        self.session = session
    }

    // MARK: - Manifest

    /// Decoded `version.json`. Only `version` is required; the rest are optional
    /// so older/minimal manifests keep parsing.
    private struct Manifest: Decodable {
        let version: String
        let downloadURL: String?
        let releaseNotes: String?
        let minimumSupported: String?
        let publishedAt: String?
    }

    // MARK: - Public entry points

    /// User-initiated check. Always shows a result alert (newer, up-to-date, or
    /// an error), so the click never feels like it did nothing.
    func checkForUpdates() {
        check(silent: false)
    }

    /// Launch / background check. Only surfaces an alert when a newer version
    /// exists; up-to-date and failure are logged silently (no interruption).
    /// Throttled to once per day so frequent app opens never nag the user or
    /// hammer the manifest host — a real update is still caught within 24h.
    func checkForUpdatesInBackground() {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.lastLaunchCheckKey) as? Date,
           Date().timeIntervalSince(last) < 86_400 {
            Log.updates.info("Skipping launch update check — already checked within 24h")
            return
        }
        defaults.set(Date(), forKey: Self.lastLaunchCheckKey)
        check(silent: true)
    }

    private static let lastLaunchCheckKey = "StatBarLastLaunchUpdateCheck"

    private func check(silent: Bool) {
        Log.updates.info("Free update check (silent: \(silent, privacy: .public), manifest: \(self.manifestURL.absoluteString, privacy: .public))")
        Task {
            do {
                let manifest = try await fetchManifest()
                presentResult(for: manifest, silent: silent)
            } catch {
                Log.updates.error("Free update check failed: \(error.localizedDescription, privacy: .public)")
                DiagnosticsStore.shared.recordUpdateCheck(result: "Failed: \(error.localizedDescription)")
                if !silent { presentError() }
            }
        }
    }

    // MARK: - Networking

    private func fetchManifest() async throws -> Manifest {
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - Alerts

    private func presentResult(for manifest: Manifest, silent: Bool) {
        let current = Self.installedVersion

        guard Self.isVersion(manifest.version, newerThan: current) else {
            DiagnosticsStore.shared.recordUpdateCheck(result: "Up to date (\(current))")
            if !silent { presentUpToDate() }
            return
        }

        let required = manifest.minimumSupported.map {
            Self.isVersion($0, newerThan: current)
        } ?? false
        DiagnosticsStore.shared.recordUpdateCheck(
            result: "Update available: \(manifest.version)\(required ? " (required)" : "")"
        )

        let alert = NSAlert()
        alert.alertStyle = required ? .warning : .informational
        alert.messageText = required
            ? "StatBar update required"
            : "A new version of StatBar is available"

        var info = "Current version: \(current)\nLatest version: \(manifest.version)"
        if let published = Self.formattedDate(manifest.publishedAt) {
            info += "\nPublished: \(published)"
        }
        if required {
            info += "\n\nThis update is required to keep StatBar working."
        }
        if let notes = manifest.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            info += "\n\nRelease notes:\n\(notes)"
        }
        alert.informativeText = info

        let downloadButton = alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")

        // Disable Download if the manifest gave no usable URL — better than
        // opening nothing on click.
        let downloadURL = manifest.downloadURL.flatMap(URL.init(string:))
        downloadButton.isEnabled = downloadURL != nil

        activateApp()
        if alert.runModal() == .alertFirstButtonReturn, let downloadURL {
            NSWorkspace.shared.open(downloadURL)
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You're up to date"
        alert.informativeText = "You're using the latest version (\(Self.installedVersion))."
        alert.addButton(withTitle: "OK")
        activateApp()
        alert.runModal()
    }

    private func presentError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = "StatBar couldn't reach the update server. Check your internet connection and try again later."
        alert.addButton(withTitle: "OK")
        activateApp()
        alert.runModal()
    }

    /// The Settings window runs as an accessory app; bring it forward so the
    /// modal alert isn't lost behind other windows.
    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Version comparison

    static var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Numeric, dot-separated comparison ("1.10.0" > "1.9.0"). Missing
    /// components are treated as 0, and any non-numeric suffix is ignored.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }

    // MARK: - Date formatting

    private static let isoParser = ISO8601DateFormatter()
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Parses an ISO-8601 `publishedAt` and reformats for display. Returns nil
    /// for missing or unparseable input (the field is optional).
    private static func formattedDate(_ raw: String?) -> String? {
        guard let raw, let date = isoParser.date(from: raw) else { return nil }
        return displayFormatter.string(from: date)
    }
}
