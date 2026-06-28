import AppKit
import CoreText
import Foundation
import LaunchAtLogin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popupController: PopupController!
    private let refreshManager = DataRefreshManager()
    private let settingsWindowController = SettingsWindowController()
    private let onboardingWindowController = OnboardingWindowController()
    private var latestMatches: [Match] = []
    /// matchID → when the app first saw that match as final. The snapshot feed
    /// has no end-time, so the followed-team companion measures its grace window
    /// from this local observation (see `MatchFocus.companion`). Pruned each
    /// refresh to matches still in range.
    private var finalSeenAt: [String: Date] = [:]

    // Stable-width bookkeeping: the reserved status-item width only grows within
    // one selection (same mode/sport/candidate) so score updates don't jitter.
    private var reservedWidth: CGFloat = 0
    private var reserveKey = ""

    /// Agent apps (.accessory) ship with no main menu, so the standard Cut/Copy/
    /// Paste/Select-All key equivalents (⌘X/C/V/A) never fire — text fields in the
    /// Settings/paywall windows can't be pasted into. Install a minimal Edit menu
    /// whose items target the responder chain (nil target) so the field editor
    /// handles them wherever the app is key.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStart = Date()
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        // Critical path first: get the menu bar item on screen ASAP (PRD §7).
        // Everything non-essential is deferred to the next runloop tick so the
        // icon appears within ~1s rather than blocking on SDK setup + network.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Score-first status item: shows the adaptive game title while a game is
        // live/final, and falls back to the app icon when idle (no decorative
        // glyph during games — see updateMenuBarLabel).
        statusItem.button?.toolTip = "StatBar"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopup(_:))
        statusItem.button?.alignment = .center
        updateMenuBarLabel(matches: [])

        popupController = PopupController(statusItem: statusItem)
        popupController.onOpenSettings = { [weak self] in
            self?.settingsWindowController.show()
        }

        // Pinning a game in the popup must update the menu bar at once,
        // not on the next poll — drives the instant-pin feel.
        popupController.onFocusChanged = { [weak self] in
            guard let self else { return }
            self.updateMenuBarLabel(matches: self.latestMatches)
        }

        let launchDuration = Date().timeIntervalSince(launchStart)
        DiagnosticsStore.shared.recordLaunchDuration(launchDuration)
        Log.lifecycle.info("Menu bar item ready in \(Int(launchDuration * 1000), privacy: .public) ms")

        // Defer the rest: SDK boots, notifications, network, first refresh.
        DispatchQueue.main.async { [weak self] in
            self?.completeStartup()
        }
    }

    /// Non-critical initialization, run after the menu bar item is on screen.
    private func completeStartup() {
        // Drop any sport that was enabled before its live feed was deferred, and
        // tell the user why (once). Runs before onboarding so returning users see
        // a clean, supported-only list.
        let disabled = UserPreferencesManager.shared.disableUnsupportedLeagues()
        if !disabled.isEmpty {
            explainDisabledLeagues(disabled)
        }

        // Updates: launch stays quiet unless checkOnLaunch is set.
        if Config.Updates.checkOnLaunch {
            FreeUpdateChecker.shared.checkForUpdatesInBackground()
        }

        // Analytics is currently disabled (no provider wired) — no-op.
        AnalyticsService.bootstrap()

        // Notifications: register the delegate/category. Permission is requested
        // at the end of first-run onboarding; returning users are asked here.
        NotificationService.shared.configure { [weak self] in
            self?.popupController.show()
        }
        DiagnosticsStore.shared.refreshNotificationAuth()

        presentOnboardingIfNeeded()

        settingsWindowController.onPreferencesChanged = { [weak self] in
            guard let self else { return }
            self.updateMenuBarLabel(matches: self.latestMatches)
        }

        let checkForUpdates: () -> Void = { FreeUpdateChecker.shared.checkForUpdates() }
        settingsWindowController.onCheckForUpdates = checkForUpdates

        // Popup quick actions: refresh, check for updates (settings is wired
        // separately above).
        popupController.onRefresh = { [weak self] in
            self?.refreshManager.refreshImmediately()
        }
        popupController.onCheckForUpdates = checkForUpdates

        refreshManager.onUpdate = { [weak self] matches in
            guard let self else { return }
            let previous = self.latestMatches
            self.latestMatches = matches
            self.updateMenuBarLabel(matches: matches)
            self.popupController.update(matches: matches)
            NotificationService.shared.process(previous: previous, current: matches)
        }

        // Connectivity: refresh immediately when the network returns.
        NetworkMonitor.shared.onReconnect = { [weak self] in
            self?.refreshManager.refreshImmediately()
        }
        NetworkMonitor.shared.start()

        // Paint cached data instantly, then start the live refresh loop.
        Task {
            let cachedMatches = await APIService.shared.loadCachedMatches()
            await MainActor.run {
                latestMatches = cachedMatches
                updateMenuBarLabel(matches: cachedMatches)
                popupController.update(matches: cachedMatches)
            }
        }

        refreshManager.start()
    }

    /// Tell the user a league was turned off because its feed is no longer
    /// available. `names` are league display names.
    private func explainDisabledLeagues(_ names: [String]) {
        let list = names.joined(separator: ", ")
        let one = names.count == 1
        let alert = NSAlert()
        alert.messageText = one ? "\(list) is unavailable" : "Some leagues are unavailable"
        alert.informativeText = "Live scores for \(list) aren't available right now, so "
            + "\(one ? "it has" : "they've") been turned off. "
            + "We'll re-enable \(one ? "it" : "them") automatically once the feed returns."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// First launch: run onboarding, which requests notification permission at
    /// its final step. Returning users skip straight to the permission prompt.
    private func presentOnboardingIfNeeded() {
        guard !UserPreferencesManager.shared.onboardingCompleted else {
            NotificationService.shared.requestPermissionIfNeeded()
            return
        }

        onboardingWindowController.onFinished = { [weak self] in
            guard let self else { return }
            self.updateMenuBarLabel(matches: self.latestMatches)
            self.popupController.update(matches: self.latestMatches)
        }
        onboardingWindowController.show()
    }

    private func updateMenuBarLabel(matches: [Match]) {
        guard let button = statusItem.button else { return }

        let prefs = UserPreferencesManager.shared
        let enabledLeagues = prefs.visibleLeagueIDs

        // Smart Focus: rank visible matches by relevance (followed team, live,
        // close score, overtime, leader) so the most worth-watching event lands
        // in the menu bar on its own — no manual pinning.
        let visible = matches.filter { enabledLeagues.contains($0.league) }
        var prioritized = MatchFocus.ranked(
            visible,
            followedTeams: prefs.followedTeams,
            affinity: prefs.interestScores
        )

        // Record first-seen-final per visible match (the feed has no end-time) so
        // the companion grace window measures from full-time, and prune matches
        // that have aged out of the feed so the map can't grow unbounded.
        let now = Date()
        let presentIDs = Set(visible.map(\.matchID))
        finalSeenAt = finalSeenAt.filter { presentIDs.contains($0.key) }
        for m in visible where m.isFinal && finalSeenAt[m.matchID] == nil {
            finalSeenAt[m.matchID] = now
        }

        // A pin only makes sense while a game is upcoming or live. Once it's
        // final, retire it — a result frozen in the menu bar isn't worth pinning,
        // and Smart Focus should take back over.
        if !prefs.autoFocusEnabled,
           let pinnedID = prefs.manualFocusMatchID,
           let pinnedMatch = visible.first(where: { $0.matchID == pinnedID }),
           pinnedMatch.isFinal {
            prefs.manualFocusMatchID = nil
            prefs.autoFocusEnabled = true
        }

        // The match the menu bar should float to the front. Two sources:
        //  • Manual focus — Auto Focus off and the user pinned a game.
        //  • Companion — Auto Focus on and the user follows teams: track *their*
        //    team through the season (live → full-time for a grace window → that
        //    team's next fixture), instead of the globally hottest game.
        let pinnedMatch: Match? = {
            if !prefs.autoFocusEnabled, let pinnedID = prefs.manualFocusMatchID {
                return prioritized.first(where: { $0.matchID == pinnedID })
            }
            if prefs.autoFocusEnabled, !prefs.followedTeams.isEmpty {
                return MatchFocus.companion(
                    forFollowed: prefs.followedTeams,
                    in: visible,
                    firstSeenFinal: finalSeenAt,
                    now: now,
                    graceWindow: Config.Focus.gracePeriod
                )
            }
            return nil
        }()
        if let pinnedMatch, let idx = prioritized.firstIndex(where: { $0.matchID == pinnedMatch.matchID }) {
            prioritized.insert(prioritized.remove(at: idx), at: 0)
        }

        // A pinned game that hasn't started yet: show "ARS vs CHE · 7:30 PM" rather
        // than the idle icon, so the user sees the match they're waiting on.
        if let pinnedMatch, !pinnedMatch.isLive, !pinnedMatch.isFinal {
            button.image = nil
            button.imagePosition = .noImage
            let font = Self.menuBarFont()
            let candidates = prefs.displayMode.upcomingMenuBarCandidates(for: pinnedMatch)
            let budget = availableWidth()
            func w(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
            let chosen = candidates.first { w($0) <= budget } ?? candidates.last ?? pinnedMatch.menuBarStartText
            button.attributedTitle = NSAttributedString(string: chosen, attributes: [.font: font])
            let key = "upcoming|\(pinnedMatch.matchID)"
            let target = w(chosen) + 14
            if key != reserveKey { reserveKey = key; reservedWidth = target }
            else { reservedWidth = max(reservedWidth, target) }
            statusItem.length = reservedWidth
            return
        }

        // Idle: no live or final game to show. Replace the textual placeholder
        // with the app icon (full-color, recognizable) instead of a "StatBar"
        // string. The icon reserves a fixed square so the swap to/from text
        // doesn't jitter neighboring menu-bar items.
        let hasGame = prioritized.contains { $0.status == "live" || $0.status == "final" }
        if !hasGame {
            button.image = Self.menuBarIcon()
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            let iconWidth = (button.image?.size.width ?? 18) + 8
            reserveKey = "idle"
            reservedWidth = iconWidth
            statusItem.length = iconWidth
            return
        }
        // A game is showing: text path. Drop any idle icon first.
        button.image = nil
        button.imagePosition = .noImage

        // Crest/flag modes: render the primary game with inline logo images
        // (NSTextAttachment) instead of an emoji. Separate from the text ladder
        // because logos are images, not measurable strings; falls through to the
        // text path below only if there's no primary game (already guarded).
        if prefs.displayMode.usesLogos,
           let primary = prioritized.first(where: { $0.status == "live" || $0.status == "final" }) {
            let title = menuBarLogoTitle(for: primary, mode: prefs.displayMode)
            button.attributedTitle = title
            let key = "\(prefs.displayMode.rawValue)|\(primary.matchID)"
            let target = title.size().width + 14
            if key != reserveKey { reserveKey = key; reservedWidth = target }
            else { reservedWidth = max(reservedWidth, target) }
            statusItem.length = reservedWidth
            return
        }

        // Adaptive: pick the richest candidate that fits the available width,
        // falling back through team+score → score → emoji as space shrinks.
        let font = Self.menuBarFont()
        let candidates = prefs.displayMode.menuBarCandidates(for: prioritized)
        func width(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }

        let budget = availableWidth()
        let index = candidates.firstIndex { width($0) <= budget } ?? candidates.count - 1
        let chosen = candidates[index]

        // Favorite-team visual priority: bold the followed side's token inside
        // the title (typography, not a badge) so a glance lands on your team.
        let attributed = NSMutableAttributedString(string: chosen, attributes: [.font: font])
        if let primary = prioritized.first(where: { $0.status == "live" || $0.status == "final" }),
           let side = MatchFocus.followedSide(primary, followedTeams: prefs.followedTeams) {
            let range = (chosen as NSString).range(of: side)
            if range.location != NSNotFound {
                let bold = Self.menuBarFont(bold: true)
                attributed.addAttribute(.font, value: bold, range: range)
            }
        }
        button.attributedTitle = attributed

        // Stable width: reserve a fixed length per selection so digit-count
        // changes don't shove neighboring menu-bar items. Monospaced digits keep
        // equal-value scores identical; the reserve only grows within a selection.
        let key = "\(prefs.displayMode.rawValue)|\(prioritized.first?.sport.rawValue ?? "none")|\(index)"
        let target = width(chosen) + 14
        if key != reserveKey {
            reserveKey = key
            reservedWidth = target
        } else {
            reservedWidth = max(reservedWidth, target)
        }
        statusItem.length = reservedWidth
    }

    /// Conservative menu-bar width budget. There is no public API for a status
    /// item's actual free space, so cap by a fraction of the host screen width.
    private func availableWidth() -> CGFloat {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let screenWidth = screen?.frame.width ?? 1440
        return min(280, screenWidth * 0.22)
    }

    /// Menu-bar font with monospaced digits so score updates don't change width.
    /// `bold` is used to emphasize a followed team's token in the title.
    private static func menuBarFont(bold: Bool = false) -> NSFont {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        let base = bold
            ? NSFont.boldSystemFont(ofSize: size)
            : NSFont.menuBarFont(ofSize: 0)
        let desc = base.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: desc, size: 0) ?? base
    }

    /// Build the menu-bar title for the two crest/flag modes: inline logo images
    /// flanking the score (`🅐 2–1 🅑`), plus short team names in `.logoTeam`.
    /// Each crest comes from the logo cache; a side whose crest hasn't loaded
    /// falls back to its abbreviation so the bar never flashes a placeholder.
    /// A followed team's name is bolded, matching the text path.
    private func menuBarLogoTitle(for match: Match, mode: DisplayMode) -> NSAttributedString {
        let font = Self.menuBarFont()
        let height = font.pointSize + 1 // crest ~ cap height, sits level with text
        let provider = LogoProvider.shared
        let followed = MatchFocus.followedSide(match, followedTeams: UserPreferencesManager.shared.followedTeams)

        func crest(_ team: String, url: String?) -> NSAttributedString {
            if let image = provider.cachedImage(forTeamID: team, sport: match.sport, league: match.league, overrideURL: url) {
                let attachment = NSTextAttachment()
                attachment.image = image
                let aspect = image.size.width / max(image.size.height, 1)
                attachment.bounds = CGRect(x: 0, y: font.descender, width: height * aspect, height: height)
                return NSAttributedString(attachment: attachment)
            }
            // Crest still loading: show the abbreviation so nothing flashes.
            return text(team, bold: team == followed)
        }
        func text(_ s: String, bold: Bool = false) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: bold ? Self.menuBarFont(bold: true) : font])
        }

        let title = NSMutableAttributedString()
        title.append(crest(match.homeTeam, url: match.homeLogo))
        title.append(text(" "))
        if mode.showsTeams { title.append(text(match.homeTeam, bold: match.homeTeam == followed)); title.append(text(" ")) }
        title.append(text("\(match.homeScore)–\(match.awayScore)"))
        title.append(text(" "))
        if mode.showsTeams { title.append(text(match.awayTeam, bold: match.awayTeam == followed)); title.append(text(" ")) }
        title.append(crest(match.awayTeam, url: match.awayLogo))
        // .logoDetailed: trailing game clock / Final, mirroring the text path.
        if mode.showsContext {
            let context = DisplayMode.contextLabel(for: match)
            if !context.isEmpty { title.append(text(" · \(context)")) }
        }
        return title
    }

    /// The idle menu-bar image: the app's own icon scaled to a menu-bar square.
    /// Drawn full-color (not a template) — the icon is an opaque rounded square,
    /// so a template mask would collapse it to a featureless silhouette. Sized
    /// to the menu-bar font height so it sits level with text in other items.
    private static func menuBarIcon() -> NSImage {
        let side = NSFont.menuBarFont(ofSize: 0).pointSize + 2 // ~18pt
        let source = NSApp.applicationIconImage ?? NSImage()
        let icon = NSImage(size: NSSize(width: side, height: side))
        icon.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                    from: .zero, operation: .sourceOver, fraction: 1.0)
        icon.unlockFocus()
        icon.isTemplate = false
        return icon
    }

    @objc private func togglePopup(_ sender: AnyObject?) {
        popupController.show()
    }

    @objc private func quitApp(_ sender: AnyObject?) {
        refreshManager.stop()
        NSApp.terminate(nil)
    }
}
