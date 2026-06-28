import SwiftUI

/// First-run onboarding, visually rebuilt (UI/UX revamp). Same five logical steps
/// and the same write-through to `UserPreferencesManager` — only the presentation
/// is new: a slim progress bar, left-aligned big titles, an animated welcome, a
/// sport-grouped league grid, logo team chips, and a *live menu-bar preview* on
/// the style step so the user sees exactly what they're choosing. The final step
/// hands control back; notifications are requested only if the user opts in.
struct OnboardingView: View {
    /// Called when onboarding finishes. `requestNotifications` is true only when
    /// the user tapped "Enable Notifications" on the last step.
    var onComplete: (_ requestNotifications: Bool) -> Void

    private let prefs = UserPreferencesManager.shared

    @State private var step = 0
    @State private var enabledLeagues: Set<String>
    @State private var followed: [Team]
    @State private var displayMode: DisplayMode
    @State private var query = ""
    @State private var logoShown = false

    /// Value-first welcome: real games happening right now, fetched once so the
    /// user sees StatBar working before being asked to configure anything.
    @State private var previewMatches: [Match] = []
    @State private var previewLoaded = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lastStep = 4

    init(onComplete: @escaping (_ requestNotifications: Bool) -> Void) {
        self.onComplete = onComplete
        let prefs = UserPreferencesManager.shared
        _enabledLeagues = State(initialValue: prefs.enabledLeagues)
        _followed = State(initialValue: prefs.followedTeams)
        _displayMode = State(initialValue: prefs.displayMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.horizontal, 28)
                .padding(.top, 20)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(28)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
                .id(step)

            Divider()
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        .frame(width: 480, height: 560)
        .background(.regularMaterial)
    }

    /// Slim top progress bar — fill grows with each step.
    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.rowFill)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(step + 1) / CGFloat(lastStep + 1))
            }
        }
        .frame(height: 5)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcomeStep
        case 1: sportsStep
        case 2: teamsStep
        case 3: styleStep
        default: notificationsStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer(minLength: 0)
            AppLogoView(size: 76)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .scaleEffect(logoShown ? 1 : 0.85)
                .opacity(logoShown ? 1 : 0)
                .onAppear {
                    guard !reduceMotion else { logoShown = true; return }
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) { logoShown = true }
                }
            VStack(spacing: Theme.Spacing.sm) {
                Text("Welcome to StatBar")
                    .font(.largeTitle.weight(.bold))
                Text("Live scores in your menu bar. Here's what's happening right now.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            livePreview
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .task { await loadPreview() }
    }

    /// Real games card on the welcome step. Reveals once the one-shot fetch lands;
    /// shows nothing (just the tagline) on an off-day or before it resolves.
    @ViewBuilder
    private var livePreview: some View {
        if !previewMatches.isEmpty {
            let anyLive = previewMatches.contains(where: \.isLive)
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.xs) {
                    if anyLive { LiveDot(size: 6) } else { Image(systemName: "calendar") }
                    Text(anyLive ? "LIVE RIGHT NOW" : "TODAY")
                }
                .font(Theme.eyebrow)
                .foregroundStyle(anyLive ? Theme.live : .secondary)
                ForEach(previewMatches.prefix(4), id: \.matchID) { previewRow($0) }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.rowFill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .padding(.horizontal, Theme.Spacing.md)
            .transition(.opacity)
        }
    }

    private func previewRow(_ match: Match) -> some View {
        let showScore = match.isLive || match.isFinal
        return HStack(spacing: Theme.Spacing.md) {
            Text(previewState(match))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(match.isLive ? Theme.live : .secondary)
                .frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                previewTeam(match.awayTeam, match.awayScore, show: showScore)
                previewTeam(match.homeTeam, match.homeScore, show: showScore)
            }
        }
    }

    private func previewTeam(_ name: String, _ score: Int, show: Bool) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(name).font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: 4)
            if show {
                Text("\(score)")
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
            }
        }
    }

    /// Leading state word for a preview row: "78'", "FT", or the kickoff time.
    private func previewState(_ match: Match) -> String {
        if match.isFinal { return "FT" }
        if match.isLive { return match.gameClock.isEmpty ? "LIVE" : match.gameClock }
        return match.scheduledTimeText
    }

    private func loadPreview() async {
        guard !previewLoaded else { return }
        previewLoaded = true
        let all = await APIService.shared.fetchAllMatches()
        let ranked = MatchFocus.ranked(all, followedTeams: [])
        withAnimation(.easeInOut(duration: 0.3)) { previewMatches = ranked }
    }

    private var sportsStep: some View {
        stepScaffold(title: "Pick your competitions",
                     subtitle: "Choose the leagues and cups to follow. Change it anytime.") {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    ForEach(LeagueCatalog.supportedSports, id: \.self) { sport in
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            if LeagueCatalog.supportedSports.count > 1 {
                                Text("\(sport.emoji)  \(sport.displayName.uppercased())")
                                    .font(Theme.eyebrow)
                                    .foregroundStyle(.tertiary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                                ForEach(LeagueCatalog.leagues(for: sport)) { league in
                                    leagueCard(league)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func leagueCard(_ league: LeagueDefinition) -> some View {
        let on = enabledLeagues.contains(league.id)
        return Button {
            if on { enabledLeagues.remove(league.id) } else { enabledLeagues.insert(league.id) }
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                LogoView(leagueID: league.id, label: league.displayName, size: 22)
                Text(league.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
            }
            .statCard(padding: Theme.Spacing.lg, selected: on)
        }
        .buttonStyle(.plain)
    }

    private var teamsStep: some View {
        stepScaffold(title: "Follow your teams",
                     subtitle: "Optional — followed teams get priority and a brand-colored highlight.") {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                searchField

                if !followed.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(followed) { team in
                            teamChip(team)
                        }
                    }
                }

                if !query.isEmpty { searchResultsList }
                Spacer(minLength: 0)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search teams", text: $query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.rowFill, in: Capsule())
    }

    private func teamChip(_ team: Team) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            LogoView(team: team, size: 18)
            Text(team.label).font(.caption).lineLimit(1)
            Button {
                followed.removeAll { $0 == team }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private var searchResultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(searchResults.prefix(8)) { team in
                    Button {
                        addTeam(team)
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            LogoView(team: team, size: 22)
                            Text(team.label)
                            Spacer()
                            Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, Theme.Spacing.sm)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .frame(maxHeight: 220)
        .background(Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var styleStep: some View {
        stepScaffold(title: "Choose a menu bar style",
                     subtitle: "How much detail do you want at a glance?") {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                menuBarPreview

                VStack(spacing: Theme.Spacing.md) {
                    ForEach(DisplayMode.allCases) { mode in
                        styleOption(mode)
                    }
                }
            }
        }
    }

    /// The standout moment: a faux menu bar showing the picked style live.
    private var menuBarPreview: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text("MENU BAR PREVIEW")
                .font(Theme.eyebrow)
                .foregroundStyle(.tertiary)
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.85))
                HStack {
                    Spacer()
                    Text(displayMode.previewExample)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.trailing, Theme.Spacing.lg)
                        .contentTransitionNumeric()
                }
            }
            .frame(height: 30)
            .animation(.easeInOut(duration: 0.25), value: displayMode)
        }
    }

    private func styleOption(_ mode: DisplayMode) -> some View {
        let on = displayMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { displayMode = mode }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName).font(.body.weight(.semibold))
                    Text(mode.previewExample)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
            }
            .statCard(padding: Theme.Spacing.lg, selected: on)
        }
        .buttonStyle(.plain)
    }

    private var notificationsStep: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 60))
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(Color.accentColor)
            VStack(spacing: Theme.Spacing.md) {
                Text("Stay in the loop")
                    .font(.largeTitle.weight(.bold))
                Text("Get notified when your teams play, score, or finish. Fine-tune this later in Settings.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: Theme.Spacing.md) {
                Button {
                    finish(requestNotifications: true)
                } label: {
                    Text("Enable Notifications")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.md)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Maybe later") { finish(requestNotifications: false) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if step > 0 && step <= lastStep {
                Button("Back") { withAnimation { step -= 1 } }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Step \(step + 1) of \(lastStep + 1)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
            Spacer()
            if step < lastStep {
                Button(step == 0 ? "Get Started" : "Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    // MARK: - Logic

    private var searchResults: [Team] {
        TeamCatalog.search(query).filter { !followed.contains($0) }
    }

    private func addTeam(_ team: Team) {
        guard followed.count < UserPreferencesManager.maxFollowedTeams else { return }
        guard !followed.contains(team) else { return }
        followed.append(team)
        query = ""
    }

    private func advance() {
        persist()
        withAnimation { step = min(step + 1, lastStep) }
    }

    private func persist() {
        prefs.enabledLeagues = enabledLeagues.isEmpty ? [LeagueCatalog.defaultLeagueID] : enabledLeagues
        prefs.followedTeams = followed
        prefs.displayMode = displayMode
    }

    private func finish(requestNotifications: Bool) {
        persist()
        prefs.onboardingCompleted = true
        onComplete(requestNotifications)
    }

    @ViewBuilder
    private func stepScaffold<C: View>(title: String, subtitle: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title).font(.title.weight(.bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
            content()
                .padding(.top, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension View {
    /// Rolling numeric transition on macOS 14+, plain text below.
    @ViewBuilder
    func contentTransitionNumeric() -> some View {
        if #available(macOS 14.0, *) {
            self.contentTransition(.numericText())
        } else {
            self
        }
    }
}
