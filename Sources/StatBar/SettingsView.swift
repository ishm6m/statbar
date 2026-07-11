import SwiftUI
import LaunchAtLogin

/// Backs SettingsView. Every mutation writes through to UserDefaults
/// immediately via UserPreferencesManager.
@MainActor
final class SettingsViewModel: ObservableObject {
    private let prefs = UserPreferencesManager.shared

    @Published var displayMode: DisplayMode { didSet { prefs.displayMode = displayMode; notifyChange() } }
    @Published var enabledLeagues: Set<String> { didSet { prefs.enabledLeagues = enabledLeagues; notifyChange() } }
    @Published var followedTeams: [Team] { didSet { prefs.followedTeams = followedTeams; notifyChange() } }
    @Published var autoFocusEnabled: Bool { didSet { prefs.autoFocusEnabled = autoFocusEnabled; notifyChange() } }
    @Published var notifyMatchStarting: Bool { didSet { prefs.notifyMatchStarting = notifyMatchStarting } }
    @Published var notifyFinalScore: Bool { didSet { prefs.notifyFinalScore = notifyFinalScore } }
    @Published var notifyGoals: Bool { didSet { prefs.notifyGoals = notifyGoals } }
    @Published var refreshSpeed: RefreshSpeed { didSet { prefs.refreshSpeed = refreshSpeed } }
    @Published var largeText: Bool { didSet { prefs.largeText = largeText } }

    @Published var searchQuery: String = ""
    @Published var teamLimitReached = false

    /// Fired after any preference that affects the menu bar changes,
    /// so the app can refresh the status item immediately.
    var onPreferencesChanged: (() -> Void)?

    init() {
        displayMode = prefs.displayMode
        autoFocusEnabled = prefs.autoFocusEnabled
        enabledLeagues = prefs.enabledLeagues
        followedTeams = prefs.followedTeams
        notifyMatchStarting = prefs.notifyMatchStarting
        notifyFinalScore = prefs.notifyFinalScore
        notifyGoals = prefs.notifyGoals
        refreshSpeed = prefs.refreshSpeed
        largeText = prefs.largeText
    }

    private func notifyChange() {
        onPreferencesChanged?()
    }

    func isLeagueEnabled(_ id: String) -> Bool { enabledLeagues.contains(id) }

    func setEnabled(_ league: LeagueDefinition, _ on: Bool) {
        var set = enabledLeagues
        if on { set.insert(league.id) } else { set.remove(league.id) }
        enabledLeagues = set
    }

    var searchResults: [Team] {
        TeamCatalog.search(searchQuery).filter { !followedTeams.contains($0) }
    }

    func addTeam(_ team: Team) {
        guard followedTeams.count < UserPreferencesManager.maxFollowedTeams else {
            teamLimitReached = true
            return
        }
        guard !followedTeams.contains(team) else { return }
        followedTeams.append(team)
        teamLimitReached = false
        searchQuery = ""
    }

    func removeTeam(_ team: Team) {
        followedTeams.removeAll { $0 == team }
        teamLimitReached = false
    }
}

struct SettingsView: View {
    @StateObject var viewModel: SettingsViewModel
    @ObservedObject private var diagnostics = DiagnosticsStore.shared
    @ObservedObject private var logoDiagnostics = LogoDiagnostics.shared
    /// Hidden Debug Information panel: revealed by tapping the version
    /// row five times. Stays collapsed for normal users.
    @State private var versionTapCount = 0
    @State private var showDebugPanel = false
    var onCheckForUpdates: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                brandHeader
                displaySection
                focusSection
                sportsSection
                teamsSection
                notificationsSection
                generalSection
                if showDebugPanel { debugSection }
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 560)
        .environment(\.dynamicTypeSize, viewModel.largeText ? .xLarge : .medium)
    }

    // MARK: - Brand header

    /// App identity row at the top of Settings — logo + name + version. Doubles
    /// as the lightweight "About" surface for a menu-bar app with no menu.
    private var brandHeader: some View {
        HStack(spacing: 12) {
            AppLogoView(size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("StatBar")
                    .font(.title3.weight(.semibold))
                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        section("Menu Bar Style") {
            Picker("Menu Bar Style", selection: $viewModel.displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Text(viewModel.displayMode.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Menu bar preview")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ZStack(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.black.opacity(0.85))
                    Text(viewModel.displayMode.previewExample)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.trailing, Theme.Spacing.lg)
                }
                .frame(height: 28)
                .animation(.easeInOut(duration: 0.25), value: viewModel.displayMode)
            }
        }
    }

    // MARK: - Focus

    private var focusSection: some View {
        section("Smart Focus") {
            Toggle("Automatic Smart Focus", isOn: $viewModel.autoFocusEnabled)
                .toggleStyle(.switch)
            Text(viewModel.autoFocusEnabled
                 ? "StatBar automatically surfaces the most relevant live game."
                 : "Auto Focus is off. The game you pick in the popup stays put.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sports

    private var sportsSection: some View {
        section("Leagues") {
            Text("Toggle leagues on or off. Only enabled leagues are polled; Smart Focus picks the most relevant live game across them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(LeagueCatalog.supportedSports, id: \.self) { sport in
                VStack(alignment: .leading, spacing: 6) {
                    if LeagueCatalog.supportedSports.count > 1 {
                        Text("\(sport.emoji)  \(sport.displayName.uppercased())")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }

                    ForEach(LeagueCatalog.leagues(for: sport)) { league in
                        HStack(spacing: 8) {
                            LogoView(leagueID: league.id, label: league.displayName, size: 20)
                            Text(league.displayName)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { viewModel.isLeagueEnabled(league.id) },
                                set: { viewModel.setEnabled(league, $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Teams

    private var teamsSection: some View {
        section("Teams") {
            HStack {
                Text("Followed teams")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.followedTeams.count)/\(UserPreferencesManager.maxFollowedTeams)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(viewModel.followedTeams.count >= UserPreferencesManager.maxFollowedTeams ? .orange : .secondary)
            }

            if viewModel.followedTeams.isEmpty {
                Text("No teams followed yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowChips(teams: viewModel.followedTeams) { team in
                    viewModel.removeTeam(team)
                }
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search teams to follow", text: $viewModel.searchQuery)
                    .textFieldStyle(.roundedBorder)
            }

            if viewModel.teamLimitReached {
                Text("You can follow up to \(UserPreferencesManager.maxFollowedTeams) teams. Remove one to add more.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !viewModel.searchQuery.isEmpty {
                VStack(spacing: 0) {
                    ForEach(viewModel.searchResults.prefix(6)) { team in
                        Button {
                            viewModel.addTeam(team)
                        } label: {
                            HStack(spacing: 8) {
                                LogoView(team: team, size: 22)
                                Text(team.label)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    if viewModel.searchResults.isEmpty {
                        Text("No teams match \"\(viewModel.searchQuery)\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 10)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        section("Notifications") {
            Toggle("Match starting (followed teams)", isOn: $viewModel.notifyMatchStarting)
            Toggle("Final score (followed teams)", isOn: $viewModel.notifyFinalScore)
            Toggle("Goals scored", isOn: $viewModel.notifyGoals)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        section("General") {
            LaunchAtLogin.Toggle("Launch at Login")

            Toggle("Larger text", isOn: $viewModel.largeText)
                .toggleStyle(.switch)
            Text("Increases the size of scores and labels in the popup for easier reading.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Refresh speed", selection: $viewModel.refreshSpeed) {
                ForEach(RefreshSpeed.allCases) { speed in
                    Text(speed.displayName).tag(speed)
                }
            }
            .pickerStyle(.menu)
            .font(.callout)

            Text(viewModel.refreshSpeed.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Version") {
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture { revealDebugPanelIfNeeded() }

            Button("Check for Updates…", action: onCheckForUpdates)
        }
    }

    // MARK: - Debug Information (hidden)

    private func revealDebugPanelIfNeeded() {
        guard !showDebugPanel else { return }
        versionTapCount += 1
        if versionTapCount >= 5 {
            withAnimation { showDebugPanel = true }
            diagnostics.refreshNotificationAuth()
        }
    }

    private var debugSection: some View {
        section("Debug Information") {
            debugRow("App version", diagnostics.appVersion)
            debugRow("Build number", diagnostics.buildNumber)
            debugRow("macOS version", diagnostics.macOSVersion)
            debugRow("Launch time", diagnostics.launchDurationText)
            debugRow("Last refresh", diagnostics.lastRefreshText)
            debugRow("API latency", diagnostics.latencyText)
            debugRow("Update URL", diagnostics.updateURL)
            debugRow("Last update check", diagnostics.lastUpdateCheckText)
            debugRow("Last update result", diagnostics.lastUpdateResult)
            debugRow("Notifications", diagnostics.notificationAuth)
            debugRow("Network", NetworkMonitor.shared.isOnline ? "Online" : "Offline")
            debugRow("Logo memory hits", "\(logoDiagnostics.memoryHits)")
            debugRow("Logo disk hits", "\(logoDiagnostics.diskHits)")
            debugRow("Logo downloads", "\(logoDiagnostics.downloads)")
            debugRow("Logo failures", "\(logoDiagnostics.failures)")
            debugRow("Logos cached", "\(logoDiagnostics.cachedCount)")
        }
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    // MARK: - Helpers

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title.uppercased())
                .font(Theme.eyebrow)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .statCard()
        }
    }
}

/// Wrapping row of removable team chips.
private struct FlowChips: View {
    let teams: [Team]
    let onRemove: (Team) -> Void

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(teams) { team in
                HStack(spacing: 6) {
                    LogoView(team: team, size: 18)
                    Text(team.label)
                        .font(.caption)
                        .lineLimit(1)
                    Button {
                        onRemove(team)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
            }
        }
    }
}
