import AppKit
import SwiftUI
import LaunchAtLogin

/// Top-anchors an NSScrollView. AppKit views are bottom-left origin, so a plain
/// clip view makes NSScrollView show the *bottom* of overflowing content first
/// and clip the top on open. Flipping the clip view puts (0,0) at the top-left,
/// so the popup always opens at its top and scrolling only moves content — never
/// reveals previously hidden chrome.
private final class TopAnchoredClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Borderless panels report `canBecomeKey == false`, so an embedded TextField
/// (the search field) can never get keyboard focus — you can't type. Override
/// it. `.nonactivatingPanel` still keeps the owner app from activating, so the
/// popup stays transient.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PopupController: NSObject, ObservableObject {
    private let statusItem: NSStatusItem
    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Kept so the panel can re-fit when async content (scores, standings)
    /// lands *after* the popup is already open —
    /// otherwise the panel stays at its open-time height and the extra content is
    /// clipped (the "half popup"). The hosting view auto-sizes to its content
    /// (`sizingOptions`); `frameObserver` watches that and re-fits the panel.
    private var hosting: NSHostingView<StatsPopupView>?
    private var scroll: NSScrollView?
    private var frameObserver: NSObjectProtocol?

    @Published var matches: [Match] = []
    /// False until the first fetch completes (success, empty, or cache). Lets the
    /// popup show a loading placeholder on cold launch instead of a premature
    /// "No games" empty state.
    @Published var hasLoaded = false
    @Published var flash = false
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    /// Popup navigation: the active league filter. `nil` = all enabled leagues
    /// across every sport (the "All" scope). Otherwise a single league id. One
    /// flat filter replaces the old two-row sport+league tab model.
    @Published var selectedLeagueID: String?

    /// Runtime search text. Non-empty collapses the grouped scoreboard into a
    /// flat, ranked result list so the user can jump straight to a game.
    @Published var searchQuery = ""

    /// Detail drill-down: the game whose timeline is shown, or nil for the list.
    /// Driven by `openDetail`/`closeDetail`; the popup renders the detail scene
    /// whenever this is non-nil.
    @Published var detailMatch: Match?
    /// The fetched timeline for `detailMatch` (goals/cards/subs), or nil while
    /// loading / when none is available.
    @Published var detailData: MatchDetail?
    /// True while the *first* detail fetch for the current game is in flight, so
    /// the detail scene shows a spinner instead of a premature empty state.
    @Published var detailLoading = false

    /// Team-page drill-down (one level above detail): the team whose page is
    /// shown, or nil. Driven by `openTeamPage`/`closeTeamPage`.
    @Published var teamPage: TeamPageContext?
    /// The fetched page (results/fixtures/standings) for `teamPage`, or nil while
    /// loading.
    @Published var teamPageData: TeamPage?
    /// True while the first team-page fetch is in flight.
    @Published var teamPageLoading = false

    /// Opens the standalone Settings window (set by AppDelegate).
    var onOpenSettings: (() -> Void)?
    /// Forces an immediate score refresh (set by AppDelegate).
    var onRefresh: (() -> Void)?
    /// Triggers the updater (set by AppDelegate).
    var onCheckForUpdates: (() -> Void)?
    /// Fired when the focus/pin or favourite-sport selection changes, so the menu
    /// bar (and notch) re-render the chosen game *immediately* instead of waiting
    /// for the next score refresh. Set by AppDelegate.
    var onFocusChanged: (() -> Void)?

    /// Spins the Refresh quick-action glyph while a manual refresh is in flight.
    @Published var isRefreshing = false

    /// League table shown in the empty state when the scoped league has no games
    /// (off-day) — ESPN's "never a dead screen". Empty until lazily fetched.
    @Published var emptyStandings: [StandingsRow] = []
    /// The league whose standings are currently loaded, so a re-render doesn't
    /// re-fetch and a scope change re-triggers.
    private var standingsLoadedFor: String?

    private let popupWidth: CGFloat = 320
    private let maxPopupHeight: CGFloat = 520
    /// Gap between the menu bar and the top of the popup.
    private let topGap: CGFloat = 6
    /// Keep this far clear of every visible screen edge.
    private let screenInset: CGFloat = 8

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func show() {
        if isShown {
            dismiss()
        } else {
            present()
        }
    }

    func update(matches: [Match]) {
        let previous = self.matches
        self.matches = matches
        hasLoaded = true
        syncSelectionToAvailable()

        // Warm logos for every team now visible, off the main thread, the moment
        // a scoreboard lands — so opening the popup paints real artwork instantly.
        LogoProvider.shared.prefetch(visibleMatches)

        if shouldFlash(previous: previous, next: matches) {
            triggerFlash()
            // Popup closed → the in-popup green flash isn't visible, so give an
            // ambient goal cue at the menu bar instead. Gated on the same opt-in
            // as goal notifications so "no goal noise" stays one switch.
            if !isShown, UserPreferencesManager.shared.notifyGoals {
                goalFeedback()
            }
        }

        refreshOpenDetail(with: matches)
        loadEmptyStandingsIfNeeded()
    }

    // MARK: - Empty-state standings

    /// The league whose table the empty state should show: the active filter, or
    /// the only enabled league when there's no filter. Nil in a multi-league "All"
    /// scope (no single table to pick — the popup keeps its league suggestions).
    var emptyStandingsLeague: LeagueDefinition? {
        if let id = selectedLeagueID { return LeagueCatalog.byID(id) }
        let visible = UserPreferencesManager.shared.visibleLeagues
        return visible.count == 1 ? visible.first : nil
    }

    /// Fetches the scoped league's standings the first time an off-day empty state
    /// appears for it. No-ops when there are games, no single league is in scope,
    /// or the table is already loaded. Resets when the scope leaves that league.
    func loadEmptyStandingsIfNeeded() {
        guard hasLoaded, currentMatches.isEmpty, let league = emptyStandingsLeague else {
            emptyStandings = []
            standingsLoadedFor = nil
            return
        }
        guard standingsLoadedFor != league.id else { return }
        standingsLoadedFor = league.id
        Task {
            let rows = await APIService.shared.fetchStandings(for: league)
            // Drop the result if the user changed scope while it was in flight.
            if emptyStandingsLeague?.id == league.id { emptyStandings = rows }
        }
    }

    /// Keep the popup's league filter pointed at something that still exists
    /// after a refresh or a settings change. Never clobbers a valid user choice
    /// (so the scope and pinned games survive the 25s refresh); only resets the
    /// filter to "All" when the chosen league is no longer enabled.
    private func syncSelectionToAvailable() {
        if let id = selectedLeagueID,
           !UserPreferencesManager.shared.visibleLeagueIDs.contains(id) {
            selectedLeagueID = nil
        }
    }

    var visibleMatches: [Match] {
        let visible = UserPreferencesManager.shared.visibleLeagueIDs
        return matches.filter { visible.contains($0.league) }
    }

    /// Matches in the popup's current navigation scope: the selected sport, and
    /// if a league is selected, narrowed to that league. Every visible view
    /// (hero, list, empty state) derives from this so a tab tap actually changes
    /// what's shown.
    var currentMatches: [Match] {
        guard let leagueID = selectedLeagueID else { return visibleMatches }
        return visibleMatches.filter { $0.league == leagueID }
    }

    /// True while the user is searching — the scoreboard switches to a flat
    /// result list.
    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Visible matches matching the query by team name or league name, in
    /// relevance order. Searches across every enabled league regardless of the
    /// league filter, so "find my team" works without first scoping the list.
    var searchResults: [Match] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let hits = visibleMatches.filter { m in
            m.homeTeam.localizedCaseInsensitiveContains(q)
                || m.awayTeam.localizedCaseInsensitiveContains(q)
                || (LeagueCatalog.byID(m.league)?.displayName.localizedCaseInsensitiveContains(q) ?? false)
        }
        return MatchFocus.ranked(hits, followedTeams: UserPreferencesManager.shared.followedTeams,
                                 affinity: UserPreferencesManager.shared.interestScores)
    }

    /// The sport category of the active league filter, or nil in the "All" scope.
    /// Drives the empty-state copy (off-season message) when one league is picked.
    var scopeSport: Sport? {
        selectedLeagueID.flatMap(LeagueCatalog.byID)?.sport
    }

    /// Sets the league filter (`nil` = all leagues across sports). Points
    /// `favouriteSport` at the chosen league's sport (Smart Focus tie-break) and
    /// drops a manual focus pin that the new scope would hide, so the hero can't
    /// keep showing an out-of-scope game.
    func selectLeague(_ leagueID: String?) {
        selectedLeagueID = leagueID
        let prefs = UserPreferencesManager.shared
        if let league = leagueID.flatMap(LeagueCatalog.byID) {
            prefs.favouriteSport = league.sport
        }
        if let leagueID, let pinnedID = prefs.manualFocusMatchID,
           !matches.contains(where: { $0.matchID == pinnedID && $0.league == leagueID }) {
            prefs.manualFocusMatchID = nil
            prefs.autoFocusEnabled = true
        }
        onFocusChanged?()
        loadEmptyStandingsIfNeeded()
    }

    /// Smart Focus pick for the popup's hero card: the most relevant match in
    /// the current scope (selected sport/league). When Auto Focus is off and the
    /// user pinned a game *that's in scope*, that pinned match wins. No
    /// cross-sport fallback — an empty scope shows the honest empty state.
    var focusMatch: Match? {
        let prefs = UserPreferencesManager.shared
        let scope = currentMatches
        if !prefs.autoFocusEnabled,
           let pinnedID = prefs.manualFocusMatchID,
           let pinned = scope.first(where: { $0.matchID == pinnedID }) {
            return pinned
        }
        return MatchFocus.primary(scope, followedTeams: prefs.followedTeams, affinity: prefs.interestScores)
    }

    /// The soonest upcoming (not yet started) match in the current scope, used
    /// for the empty state when nothing is live or final.
    var nextScheduledMatch: Match? {
        rankedCurrentMatches.first { !$0.isLive && !$0.isFinal }
    }

    /// Pins `match` as the manual focus and turns Auto Focus off so the choice
    /// sticks. Moves the popup scope to that match's sport/league so the hero and
    /// list both reflect it.
    func selectManualFocus(_ match: Match) {
        // Pinning a finished game is pointless — the result won't change and it'd
        // freeze the menu bar on a stale score. Only live/upcoming games pin.
        guard !match.isFinal else { return }
        let prefs = UserPreferencesManager.shared
        prefs.autoFocusEnabled = false
        prefs.manualFocusMatchID = match.matchID
        prefs.favouriteSport = match.sport
        // If a league filter is active and would hide this game, widen to "All"
        // so the pinned game stays visible in the list.
        if let id = selectedLeagueID, id != match.league { selectedLeagueID = nil }
        objectWillChange.send()
        // Push the pin to the menu bar/notch right now — the whole point of the
        // tap is "show this game up there", so it must not wait for the next poll.
        onFocusChanged?()
    }

    /// Current-scope matches in relevance order, for the popup's game list.
    var rankedCurrentMatches: [Match] {
        let prefs = UserPreferencesManager.shared
        return MatchFocus.ranked(currentMatches, followedTeams: prefs.followedTeams, affinity: prefs.interestScores)
    }

    /// Current-scope *non-live* games grouped by league for the ESPN-style browse
    /// list: each league's games ordered Upcoming (soonest) → Final (most recent),
    /// leagues in catalog order. Live games are deliberately excluded — they're
    /// promoted into one flat cross-league Live section above this (live-first).
    /// The popup uses this only when more than one league is in view.
    var leagueGroups: [(league: LeagueDefinition, matches: [Match])] {
        let order = UserPreferencesManager.shared.activeLeagues.map(\.id)
        return Dictionary(grouping: currentMatches.filter { !$0.isLive }, by: \.league)
            .compactMap { id, games -> (league: LeagueDefinition, matches: [Match])? in
                guard let league = LeagueCatalog.byID(id) else { return nil }
                let upcoming = games.filter { !$0.isFinal }
                    .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
                let finals = games.filter(\.isFinal)
                    .sorted { ($0.kickoff ?? .distantPast) > ($1.kickoff ?? .distantPast) }
                return (league, upcoming + finals)
            }
            .sorted { a, b in
                (order.firstIndex(of: a.league.id) ?? .max)
              < (order.firstIndex(of: b.league.id) ?? .max)
            }
    }

    // MARK: - ESPN-style sections

    /// Live games in current scope, in relevance order (followed team / close /
    /// overtime first). Top section of the scoreboard.
    var liveMatches: [Match] {
        rankedCurrentMatches.filter(\.isLive)
    }

    /// Not-yet-started games in current scope, soonest kickoff first — so the
    /// next game to watch is at the top of the Upcoming section. Games without a
    /// kickoff time sort last.
    var upcomingMatches: [Match] {
        currentMatches
            .filter { !$0.isLive && !$0.isFinal }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
    }

    /// Finished games in current scope, most recent first — yesterday's/this
    /// morning's results, the way ESPN lists finals.
    var finalMatches: [Match] {
        currentMatches
            .filter(\.isFinal)
            .sorted { ($0.kickoff ?? .distantPast) > ($1.kickoff ?? .distantPast) }
    }

    func toggleLaunchAtLogin() {
        LaunchAtLogin.isEnabled.toggle()
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func openSettings() {
        dismiss()
        onOpenSettings?()
    }

    /// Supported leagues that are likely playing right now but aren't enabled —
    /// what the empty state offers when the user's own leagues are off-season.
    /// One league per in-season sport (the catalog's top pick) so the suggestion
    /// stays short. Empty when everything in season is already on.
    var suggestedInSeasonLeagues: [LeagueDefinition] {
        let prefs = UserPreferencesManager.shared
        let enabled = prefs.enabledLeagues
        var seenSport = Set<Sport>()
        return LeagueCatalog.supported.filter { league in
            guard league.sport.isInSeason(),
                  !enabled.contains(league.id),
                  seenSport.insert(league.sport).inserted else { return false }
            return true
        }
    }

    /// Enables `league` from the empty-state suggestion, points the popup at its
    /// sport, and kicks an immediate refresh so games appear without a settings
    /// detour.
    func enableSuggestedLeague(_ league: LeagueDefinition) {
        let prefs = UserPreferencesManager.shared
        prefs.toggleLeague(league.id)
        selectedLeagueID = league.id
        prefs.favouriteSport = league.sport
        objectWillChange.send()
        onFocusChanged?()
        onRefresh?()
    }

    // MARK: - Detail drill-down

    /// The game shown in the menu bar right now: the most relevant of all visible
    /// matches, with a manual pin floated to the front (mirrors AppDelegate's
    /// menu-bar pick). Drives the jump-straight-to-detail behaviour on open.
    var menuBarMatch: Match? {
        let prefs = UserPreferencesManager.shared
        let ranked = MatchFocus.ranked(
            visibleMatches, followedTeams: prefs.followedTeams, affinity: prefs.interestScores
        )
        // An explicit, still-relevant pin (live or upcoming) wins outright — even
        // when it hasn't kicked off — so a click lands on the game the user chose,
        // not on whatever else happens to be live. A finished pin is ignored (it
        // gets retired on the next poll) so it can't freeze the menu bar.
        if !prefs.autoFocusEnabled, let pinnedID = prefs.manualFocusMatchID,
           let pinned = ranked.first(where: { $0.matchID == pinnedID }), !pinned.isFinal {
            return pinned
        }
        return ranked.first { $0.isLive || $0.isFinal } ?? ranked.first
    }

    /// True when a game's detail can be shown: a match with an event id, once it's
    /// live or final — the soccer goal/card timeline.
    func hasDetail(_ match: Match) -> Bool {
        match.espnEventID != nil && (match.isLive || match.isFinal)
    }

    /// Opens the timeline detail for `match` and kicks off its fetch. Records the
    /// open as an interest signal so Smart Focus learns which games you drill into.
    func openDetail(_ match: Match) {
        UserPreferencesManager.shared.recordInterest(in: match)
        closeTeamPage()
        detailMatch = match
        detailData = nil
        loadDetail()
        scheduleFit()
    }

    /// Re-fit the panel to the active scene after a navigation. SwiftUI needs a
    /// runloop tick to lay the new scene out, so defer one hop; `fitToContent`
    /// no-ops when the panel isn't up yet (e.g. these are called during `present()`
    /// before the panel exists).
    private func scheduleFit() {
        DispatchQueue.main.async { [weak self] in self?.fitToContent() }
    }

    // MARK: - Team page

    /// Whether `match`'s side has a team page available — needs the team's ESPN id
    /// (older cached matches lack it).
    func hasTeamPage(_ match: Match, home: Bool) -> Bool {
        (home ? match.homeTeamID : match.awayTeamID) != nil
    }

    /// Opens the team page for one side of `match` (home or away) and fetches it.
    /// Records the open as a strong interest signal.
    func openTeamPage(_ match: Match, home: Bool) {
        guard let teamID = home ? match.homeTeamID : match.awayTeamID else { return }
        UserPreferencesManager.shared.recordInterest(in: match)
        let context = TeamPageContext(
            teamID: teamID,
            teamName: home ? match.homeTeam : match.awayTeam,
            leagueID: match.league,
            sport: match.sport,
            logoURL: home ? match.homeLogo : match.awayLogo
        )
        teamPage = context
        teamPageData = nil
        teamPageLoading = true
        scheduleFit()
        Task { [weak self] in
            let page = await APIService.shared.fetchTeamPage(
                leagueID: context.leagueID, teamID: context.teamID, teamName: context.teamName
            )
            await MainActor.run {
                guard let self, self.teamPage?.teamID == context.teamID else { return }
                self.teamPageData = page
                self.teamPageLoading = false
            }
        }
    }

    /// Returns from the team page to whatever was underneath (the match detail or
    /// the list).
    func closeTeamPage() {
        teamPage = nil
        teamPageData = nil
        teamPageLoading = false
        scheduleFit()
    }

    /// Returns to the game list from the detail scene. Also drops any team page
    /// opened above it, so a return to the list never leaves a stale page behind.
    func closeDetail() {
        detailMatch = nil
        detailData = nil
        detailLoading = false
        closeTeamPage()
    }

    /// Fetches the current `detailMatch`'s timeline. Shows the spinner only on the
    /// first load (when no data is cached in memory yet); a live re-fetch updates
    /// silently underneath the existing timeline.
    private func loadDetail() {
        guard let match = detailMatch else { return }
        detailLoading = detailData == nil
        Task { [weak self] in
            let detail = await APIService.shared.fetchMatchDetail(for: match)
            await MainActor.run {
                guard let self, self.detailMatch?.matchID == match.matchID else { return }
                if let detail { self.detailData = detail }
                self.detailLoading = false
            }
        }
    }

    /// On each poll, keep an open detail scene's header score fresh and re-fetch
    /// the timeline while the game is live. Closes the scene if the game drops out
    /// of the feed entirely.
    private func refreshOpenDetail(with matches: [Match]) {
        guard let current = detailMatch else { return }
        guard let fresh = matches.first(where: { $0.matchID == current.matchID }) else {
            return // keep the last snapshot; don't blank a game mid-view
        }
        detailMatch = fresh
        if fresh.isLive { loadDetail() }
    }

    /// Quick action: force an immediate refresh, briefly spinning the glyph.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        onRefresh?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.isRefreshing = false
        }
    }

    /// Quick action: trigger an update check.
    func checkForUpdates() {
        onCheckForUpdates?()
    }

    func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Presentation

    private func present() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        // Jump straight to the menu-bar game's timeline when it has one, so a
        // click on the menu bar lands on "my game's story" in one tap. Otherwise
        // open the list. (User choice: jump-to-pinned-detail.)
        if let menuBarMatch, hasDetail(menuBarMatch) {
            openDetail(menuBarMatch)
        } else {
            closeDetail()
        }

        let hosting = NSHostingView(rootView: StatsPopupView(controller: self))
        hosting.wantsLayer = true
        // The SwiftUI view self-caps its height and scrolls internally (top-
        // anchored), so the hosting view never exceeds the panel — the AppKit
        // scroll view below stays a passive container and can't bottom-anchor.
        // Let the hosting view drive its own height from the SwiftUI content, so
        // it grows/shrinks as async content (scores, standings) lands. Width
        // stays pinned to the popup width.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.setFrameSize(NSSize(width: popupWidth, height: hosting.fittingSize.height))
        hosting.layoutSubtreeIfNeeded()
        self.hosting = hosting

        // Always host the content in a scroll view: when it fits, nothing
        // scrolls; when it grows past the cap (or after open), the overflow
        // scrolls instead of being clipped. `fitToContent` keeps the panel
        // height tracking the content's actual frame while it's open.
        let natural = max(hosting.fittingSize.height, 1)
        let height = min(natural, maxPopupHeight)
        let size = NSSize(width: popupWidth, height: height)

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        // Top-anchor the content so the popup opens showing its top edge, not its
        // bottom (AppKit's default for an overflowing, non-flipped document view).
        scroll.contentView = TopAnchoredClipView()
        scroll.documentView = hosting
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        self.scroll = scroll
        let content: NSView = scroll

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.contentView = content
        panel.setFrame(popupFrame(size: size, button: button, buttonWindow: buttonWindow), display: false)
        self.panel = panel

        // Native-feeling entrance: fade 0→1 and scale 0.98→1.0, 200ms ease-out.
        // No spring/bounce.
        panel.alphaValue = 0
        let layer = content.layer
        layer?.transform = CATransform3DMakeScale(0.98, 0.98, 1)
        panel.orderFrontRegardless()
        panel.makeKey() // so the search TextField can take keyboard focus

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.98
        scale.toValue = 1.0
        scale.duration = 0.2
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(scale, forKey: "present")
        layer?.transform = CATransform3DIdentity

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        // The hosting view re-sizes its own frame whenever SwiftUI content
        // changes (sizingOptions). Watch that — authoritative and correctly
        // timed, unlike re-measuring fittingSize ourselves — and re-fit the panel
        // so late-arriving content grows it instead of being clipped.
        hosting.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: hosting, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToContent() }
        }

        installMonitors()
    }

    /// Resize the open panel to fit the hosting view's current content height,
    /// keeping the top edge anchored under the menu bar. No-op when unchanged.
    private func fitToContent() {
        guard let panel, let hosting, let scroll, panel.isVisible,
              let button = statusItem.button, let buttonWindow = button.window else { return }
        // Force the hosting view to recompute its intrinsic height *now*, so the
        // measurement reflects the scene we just switched to instead of a stale
        // frame — this is what lets the panel shrink back (e.g. list → detail), not
        // just grow.
        hosting.layoutSubtreeIfNeeded()
        let natural = max(hosting.frame.height, 1)
        let height = min(natural, maxPopupHeight)
        guard abs(panel.frame.height - height) >= 0.5 else { return }
        let size = NSSize(width: popupWidth, height: height)
        scroll.setFrameSize(size)
        let frame = popupFrame(size: size, button: button, buttonWindow: buttonWindow)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    func dismiss() {
        guard let panel = panel else { return }
        self.panel = nil
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        hosting = nil
        scroll = nil
        removeMonitors()

        let layer = panel.contentView?.layer
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 0.98
        scale.duration = 0.15
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer?.add(scale, forKey: "dismiss")
        layer?.transform = CATransform3DMakeScale(0.98, 0.98, 1)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    /// Frame for the popup: centered under the status item, just below the menu
    /// bar, fully clamped to the host screen's visible bounds (which already
    /// excludes the menu bar — and the notch region — and the Dock).
    private func popupFrame(size: NSSize, button: NSStatusBarButton, buttonWindow: NSWindow) -> NSRect {
        let buttonInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        // Horizontal: center under the button, clamp inside the screen.
        var x = buttonInScreen.midX - size.width / 2
        x = min(max(x, visible.minX + screenInset), visible.maxX - size.width - screenInset)

        // Vertical: hang from just under the button, clamp to the visible area.
        var top = min(buttonInScreen.minY - topGap, visible.maxY)
        var y = top - size.height
        if y < visible.minY + screenInset {
            y = visible.minY + screenInset
            top = y + size.height
        }
        if top > visible.maxY {
            y = visible.maxY - size.height
        }

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Transient behavior

    private func installMonitors() {
        // Clicks in other apps dismiss the popup.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        // Clicks inside this app dismiss too — except on the status item itself,
        // whose action handler toggles, and except inside the popup. Esc closes.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismiss() } // Esc
                    return
                }
                let buttonWindow = self.statusItem.button?.window
                if event.window != self.panel && event.window != buttonWindow {
                    self.dismiss()
                }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// Flash only when the *hero* game (the one shown big in the popup) changes
    /// score or state — not any game in the feed. Matched by `matchID` so a
    /// re-ranking between refreshes can't masquerade as a score change.
    private func shouldFlash(previous: [Match], next: [Match]) -> Bool {
        guard let hero = focusMatch,
              let old = previous.first(where: { $0.matchID == hero.matchID }) else {
            return false
        }
        return old.homeScore != hero.homeScore
            || old.awayScore != hero.awayScore
            || old.status != hero.status
    }

    private func triggerFlash() {
        flash = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.flash = false
        }
    }

    /// Goal moment when the popup is closed: a short system sound, a trackpad
    /// haptic tap, and a ~1s green tint on the menu-bar glyph. All three are
    /// no-ops where unsupported (no force-touch trackpad, sound muted), so no
    /// capability checks needed.
    private func goalFeedback() {
        NSSound(named: "Glass")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        // ponytail: one shared goal green, not the scoring team's brand color —
        // teams don't carry a color yet. Swap to per-team when Team gains one.
        guard let button = statusItem.button else { return }
        button.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak button] in
            button?.contentTintColor = nil
        }
    }
}
