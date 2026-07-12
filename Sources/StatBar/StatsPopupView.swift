import SwiftUI
import AppKit

/// The menu-bar popup: a dense, scan-first scoreboard rather than one oversized
/// hero card. Every game is a two-line cell —
/// away over home, scores right-aligned and monospaced, state/clock in a fixed
/// leading column, a 3pt brand-color edge so the eye finds a game by team color.
/// The Smart-Focus pick (`controller.focusMatch`) sits at the top and is the one
/// row that expands with situation context + Watch/ESPN actions; everything else
/// stays tight so more games fit above the fold.
struct StatsPopupView: View {
    @ObservedObject var controller: PopupController
    @ObservedObject private var network = NetworkMonitor.shared
    /// matchID of the row under the cursor, so a "Pin to menu bar" affordance can
    /// appear on hover (discoverability: a bare row tap doesn't say it pins).
    @State private var hoveredRow: String?

    private var prefs: UserPreferencesManager { .shared }

    /// Hard ceiling on the popup's height. Past this the content scrolls — in
    /// SwiftUI, top-anchored — so the popup is never taller than the screen and
    /// always opens showing its top. Mirrors `PopupController.maxPopupHeight`.
    private let maxPopupHeight: CGFloat = 520

    /// Reduce Motion: skip the goal-flash scale bounce (the green tint still fires
    /// as a non-motion cue).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Larger-text legibility (Settings → General). Scales the two fixed-size
    /// readouts (team name, score); semantic-font chrome scales via the injected
    /// dynamicTypeSize below. ponytail: a flat multiplier — the dense 320pt layout
    /// can't take per-style Dynamic Type without reflowing.
    private var textScale: CGFloat { prefs.largeText ? 1.3 : 1 }

    var body: some View {
        scene
            .frame(width: 320)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.popup, style: .continuous))
            .environment(\.dynamicTypeSize, prefs.largeText ? .xLarge : .medium)
    }

    /// The popup's scrollable body. Every scene shares one contract: size to its
    /// content, cap at `maxPopupHeight`, scroll past that. The panel re-fits to the
    /// active scene on each navigation (`PopupController.fitToContent`). All
    /// top-anchored — scrolling moves content, never reveals hidden chrome.
    @ViewBuilder
    private var scene: some View {
        if let teamPage = controller.teamPage {
            TeamPageScene(controller: controller, context: teamPage)
                .frame(maxHeight: maxPopupHeight)
        } else if let detail = controller.detailMatch {
            MatchDetailScene(controller: controller, match: detail)
                .frame(maxHeight: maxPopupHeight)
        } else {
            ScrollView(.vertical) {
                listScene
            }
            .frame(maxHeight: maxPopupHeight)
        }
    }

    /// The default scene: header + league filter + grouped scoreboard + footer.
    private var listScene: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if !network.isOnline { offlineBanner }

            header

            if showsSearchField { searchField }

            content

            Divider()
            quickActionsFooter
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Search

    /// Show the search box only when there's a loaded scoreboard worth filtering.
    private var showsSearchField: Bool {
        controller.hasLoaded && !controller.visibleMatches.isEmpty
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search teams or leagues", text: $controller.searchQuery)
                .textFieldStyle(.plain)
                .font(.callout)
            if !controller.searchQuery.isEmpty {
                Button { controller.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .floatingGlass(Capsule())
    }

    /// Flat, ranked result list while searching — tap a row to pin/open it, the
    /// same actions as the scoreboard. Honest empty state when nothing matches.
    @ViewBuilder
    private var searchResultsView: some View {
        let results = controller.searchResults
        if results.isEmpty {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No matches for “\(controller.searchQuery)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xl)
        } else {
            let focusID = controller.focusMatch?.matchID
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(results, id: \.matchID) { match in
                    scoreRow(match, focused: match.matchID == focusID)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            leagueFilter
            Spacer()
            if liveCount > 0 {
                HStack(spacing: 4) {
                    LiveDot(size: 6)
                    Text("\(liveCount) live")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.live)
                }
            }
            Button { controller.openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Open Settings")
        }
    }

    // MARK: - League filter

    /// Single dropdown that scopes the list — replaces the old two rows of sport
    /// and league chips. Collapses to a plain "StatBar" title when there's only
    /// one league to show (nothing to filter). "All Leagues" picks the across-
    /// sport scope; each enabled league narrows to it.
    @ViewBuilder
    private var leagueFilter: some View {
        let leagues = prefs.activeLeagues
        if leagues.count > 1 {
            Menu {
                Button {
                    controller.selectLeague(nil)
                } label: {
                    Label("All Leagues", systemImage: controller.selectedLeagueID == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(leagues) { league in
                    Button {
                        controller.selectLeague(league.id)
                    } label: {
                        Label(league.displayName,
                              systemImage: controller.selectedLeagueID == league.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentScopeName)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xxs)
                .floatingGlass(Capsule(), fallback: .clear)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by league")
        } else {
            Text("StatBar").font(.headline)
        }
    }

    /// The label for the current league scope, shown on the dropdown.
    private var currentScopeName: String {
        guard let id = controller.selectedLeagueID,
              let league = LeagueCatalog.byID(id) else { return "All Leagues" }
        return league.displayName
    }

    // MARK: - Content switch

    @ViewBuilder
    private var content: some View {
        if controller.isSearching {
            searchResultsView
        } else if !controller.hasLoaded {
            loadingState
        } else if controller.currentMatches.isEmpty {
            emptyState
        } else {
            scoreboard
        }
    }

    // MARK: - Scoreboard

    private var liveCount: Int { controller.liveMatches.count }

    /// ESPN-style scoreboard, live-first. Live games across every league in scope
    /// are promoted into one flat Live section at the very top (the only time-
    /// sensitive content — the way ESPN/Apple surface in-progress games). Below it,
    /// with more than one league in view, the *remaining* games group under league
    /// headers (Upcoming → Final) for browsing; with a single league in scope the
    /// header would just echo the filter, so it falls back to flat Upcoming / Final.
    private var scoreboard: some View {
        let focusID = controller.focusMatch?.matchID
        let groups = controller.leagueGroups
        return VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            section("Live", isLive: true, matches: controller.liveMatches, cap: 8, focusID: focusID)
            if groups.count > 1 {
                ForEach(groups, id: \.league.id) { group in
                    leagueSection(group.league, matches: group.matches, focusID: focusID)
                }
            } else {
                section("Upcoming", isLive: false, matches: controller.upcomingMatches, cap: 8, focusID: focusID)
                section("Full Time", isLive: false, matches: controller.finalMatches, cap: 8, focusID: focusID)
            }
        }
    }

    /// One league block: a name header (with a live count) over that league's
    /// games. ponytail: text header, no crest — LogoView resolves *team* art, so
    /// a league id would render a wrong monogram rather than the comp's badge.
    private func leagueSection(_ league: LeagueDefinition, matches: [Match], focusID: String?) -> some View {
        let live = matches.filter(\.isLive).count
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(league.displayName.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if live > 0 {
                    HStack(spacing: 3) {
                        LiveDot(size: 5)
                        Text("\(live)").font(.caption2.weight(.bold)).foregroundStyle(Theme.live)
                    }
                } else {
                    Text("\(matches.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.rowFill, in: Capsule())
                }
                Spacer()
            }
            ForEach(Array(matches.prefix(6)), id: \.matchID) { match in
                scoreRow(match, focused: match.matchID == focusID)
            }
        }
    }

    /// One labeled scoreboard section. Header shows the state and a game count;
    /// hidden entirely when the section is empty so off-season sports don't render
    /// dead headers.
    @ViewBuilder
    private func section(_ title: String, isLive: Bool, matches: [Match], cap: Int, focusID: String?) -> some View {
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.xs) {
                    if isLive { LiveDot(size: 5) }
                    Text(title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isLive ? Theme.live : .secondary)
                    Text("\(matches.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.rowFill, in: Capsule())
                    Spacer()
                }
                ForEach(Array(matches.prefix(cap)), id: \.matchID) { match in
                    scoreRow(match, focused: match.matchID == focusID)
                }
            }
        }
    }

    private func scoreRow(_ match: Match, focused: Bool) -> some View {
        let followed = MatchFocus.followedSide(match, followedTeams: prefs.followedTeams)
        let showScores = match.isLive || match.isFinal
        return Button {
            // Finished games open their story but don't pin (a result in the menu
            // bar is dead weight). Live/upcoming games pin to the menu bar, and
            // still open a timeline when one exists.
            if !match.isFinal {
                controller.selectManualFocus(match)
            }
            if controller.hasDetail(match) {
                controller.openDetail(match)
            }
        } label: {
            VStack(spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.md) {
                    stateColumn(match)
                    VStack(spacing: 3) {
                        teamLine(match.awayTeam, score: match.awayScore, logoURL: match.awayLogo,
                                 match: match, followed: match.awayTeam == followed,
                                 winner: winner(match, homeSide: false), showScore: showScores,
                                 flashing: focused && controller.flash)
                        teamLine(match.homeTeam, score: match.homeScore, logoURL: match.homeLogo,
                                 match: match, followed: match.homeTeam == followed,
                                 winner: winner(match, homeSide: true), showScore: showScores,
                                 flashing: focused && controller.flash)
                    }
                }
                if let stage = match.stage {
                    Text(stage)
                        .font(.system(size: 9 * textScale, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if focused && showScores { focusedExtras(match) }
            }
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.lg)
            .background(focused ? Theme.rowFillSelected : Theme.rowFill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.35) : Theme.hairline)
            )
            .overlay(alignment: .topTrailing) { pinIndicator(match) }
            .brandEdge(edgeHex(match, followed: followed))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredRow = $0 ? match.matchID : (hoveredRow == match.matchID ? nil : hoveredRow) }
        .help(helpText(match))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: match))
        .accessibilityHint(helpText(match))
    }

    /// VoiceOver readout for a score row, in the row's visual order (away over
    /// home). Plain language so the state isn't carried by color alone.
    private func accessibilityLabel(for match: Match) -> String {
        let away = match.awayTeam, home = match.homeTeam
        if match.isFinal {
            let ot = MatchFocus.isOvertime(match) ? " after extra time" : ""
            return "Full time\(ot). \(away) \(match.awayScore), \(home) \(match.homeScore)."
        }
        if match.isLive {
            let clock = match.gameClock.isEmpty ? "in progress" : match.gameClock
            return "Live, \(clock). \(away) \(match.awayScore), \(home) \(match.homeScore)."
        }
        return "\(away) versus \(home), \(match.scheduledTimeText)."
    }

    /// Row tooltip: finals open their story; live/upcoming pin to the menu bar.
    private func helpText(_ match: Match) -> String {
        if match.isFinal {
            return controller.hasDetail(match) ? "View game details" : "Full time"
        }
        return isPinned(match) ? "Showing in menu bar" : "Click to pin to menu bar"
    }

    /// True when this game is the user's explicit menu-bar pin (Auto Focus off and
    /// this matchID pinned). Drives the "in menu bar" badge.
    private func isPinned(_ match: Match) -> Bool {
        !prefs.autoFocusEnabled && prefs.manualFocusMatchID == match.matchID
    }

    /// Per-row pin affordance. Pinned game shows a filled pin + "Menu bar" so it's
    /// clear which game is up top; any other row reveals a faint outline pin on
    /// hover, telling the user a tap pins it there (fixes the hidden-action gap).
    @ViewBuilder
    private func pinIndicator(_ match: Match) -> some View {
        if isPinned(match) {
            HStack(spacing: 3) {
                Image(systemName: "pin.fill")
                Text("Menu bar")
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .padding(6)
        } else if hoveredRow == match.matchID && !match.isFinal {
            // Only live/upcoming games are pinnable; no pin hint on finished rows.
            Image(systemName: "pin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(7)
        }
    }

    /// Fixed-width leading column: live dot + state word ("78'", "FT",
    /// scheduled time). Keeps every row's teams aligned regardless of state.
    private func stateColumn(_ match: Match) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if match.isLive { LiveDot(size: 6) }
            Text(stateText(match))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(match.isLive ? Theme.live : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let day = finalDayText(match) {
                Text(day)
                    .font(.system(size: 9 * textScale, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 54, alignment: .leading)
    }

    /// Day a finished game was played ("Yesterday", "Mon"), shown under "Final"
    /// so older results don't read as today's. Nil for today's finals (no clutter)
    /// and for non-final rows.
    private func finalDayText(_ match: Match) -> String? {
        guard match.isFinal, let kickoff = match.kickoff else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(kickoff) { return nil }
        if cal.isDateInYesterday(kickoff) { return "Yesterday" }
        return kickoff.formatted(.dateTime.weekday(.abbreviated))
    }

    private func teamLine(_ name: String, score: Int, logoURL: String?, match: Match,
                          followed: Bool, winner: Bool, showScore: Bool, flashing: Bool) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            LogoView(teamID: name, sport: match.sport, league: match.league,
                     label: name, size: 16 * textScale, overrideURL: logoURL)
            Text(name)
                .font(.system(size: 12 * textScale, weight: .semibold))
                .fontWeight(followed ? .heavy : .semibold)
                .foregroundStyle(followed ? Color.accentColor : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if showScore {
                scoreText(score, winner: winner, flashing: flashing)
            }
        }
    }

    /// One side's score. Loser dims on finals; the focused game's score pops +
    /// tints green and rolls (macOS 14+) when `controller.flash` fires.
    @ViewBuilder
    private func scoreText(_ value: Int, winner: Bool, flashing: Bool) -> some View {
        let base = Text("\(value)")
            .font(.system(size: 15 * textScale, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(flashing ? Theme.live : (winner ? Color.primary : Color.secondary))
        Group {
            if #available(macOS 14.0, *) {
                base.contentTransition(.numericText())
            } else {
                base
            }
        }
        .scaleEffect(flashing && !reduceMotion ? 1.12 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: flashing)
        .animation(.easeInOut(duration: 0.3), value: value)
    }

    /// The focused row's extra detail: a single situation line.
    private func focusedExtras(_ match: Match) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let ctx = contextStat(for: match) {
                Text(ctx)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, Theme.Spacing.xs)
    }

    // MARK: - Row helpers

    /// True when this side is winning (or tied) on a final, else true so live
    /// scores never dim. Drives loser-dimming on finished games.
    private func winner(_ match: Match, homeSide: Bool) -> Bool {
        guard match.isFinal else { return true }
        return homeSide ? match.homeScore >= match.awayScore
                        : match.awayScore >= match.homeScore
    }

    /// Brand-edge color: the followed team's color when one is in the match
    /// (highlights games you care about), else the home team's.
    private func edgeHex(_ match: Match, followed: String?) -> String? {
        if let followed {
            return followed == match.homeTeam ? match.homeColor : match.awayColor
        }
        return match.homeColor ?? match.awayColor
    }

    /// Leading-column state word.
    private func stateText(_ match: Match) -> String {
        if match.isFinal { return MatchFocus.isOvertime(match) ? "AET" : "FT" }
        if match.isLive {
            if MatchFocus.isOvertime(match) { return "OT" }
            return match.gameClock.isEmpty ? "Live" : match.gameClock
        }
        return match.scheduledTimeText
    }

    // MARK: - States

    /// Shown instead of an error when connectivity drops.
    private var offlineBanner: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "wifi.slash").foregroundStyle(.orange)
            Text("Offline, showing last known scores")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    /// Off-day empty state. ESPN never shows a dead screen: when one league is in
    /// scope and its table has loaded, show the standings; otherwise fall back to
    /// the honest off-season note + "leagues playing now" suggestions.
    @ViewBuilder
    private var emptyState: some View {
        if !controller.emptyStandings.isEmpty, let league = controller.emptyStandingsLeague {
            standingsEmptyState(controller.emptyStandings, league: league)
        } else {
            suggestionEmptyState
        }
    }

    /// The scoped league's table, shown when there are no games today — the
    /// "always something to look at" surface. Scrolls within the popup so a full
    /// 20-team table never blows past the panel height.
    private func standingsEmptyState(_ rows: [StandingsRow], league: LeagueDefinition) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text("No games today").font(.subheadline.weight(.semibold))
                Spacer()
                Text("TABLE").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            standingsHeaderRow
            // No inner ScrollView: the whole popup scrolls as one (top-anchored),
            // so a 20-team table never nests a second vertical scroller.
            VStack(spacing: 1) {
                ForEach(rows) { row in standingsRow(row) }
            }
        }
    }

    /// Column header for the mini table: # · Team · P · GD · Pts (the compact
    /// columns that fit the 320pt popup; W-D-L is dropped to keep it legible).
    private var standingsHeaderRow: some View {
        standingsCells(pos: "#", team: "Team", played: "P", gd: "GD", pts: "Pts")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.sm)
    }

    private func standingsRow(_ row: StandingsRow) -> some View {
        standingsCells(pos: row.rank, team: row.team, played: row.played,
                       gd: row.goalDiff, pts: row.points)
            .font(.caption)
            .foregroundStyle(row.isMatchTeam ? Color.accentColor : .primary)
            .padding(.vertical, 3)
            .padding(.horizontal, Theme.Spacing.sm)
            .background(row.isMatchTeam ? Theme.rowFillSelected : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func standingsCells(pos: String, team: String, played: String,
                                gd: String, pts: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(pos).frame(width: 18, alignment: .trailing).foregroundStyle(.secondary)
            Text(team).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(played).frame(width: 22, alignment: .trailing).monospacedDigit()
            Text(gd).frame(width: 32, alignment: .trailing).monospacedDigit()
            Text(pts).frame(width: 28, alignment: .trailing).fontWeight(.semibold).monospacedDigit()
        }
    }

    /// Truly nothing in scope — no live, final, or scheduled matches. Offer the
    /// leagues that *are* playing right now (one tap to add + refresh), instead
    /// of implying the feed is broken.
    private var suggestionEmptyState: some View {
        let suggestions = Array(controller.suggestedInSeasonLeagues.prefix(3))

        return VStack(spacing: Theme.Spacing.md) {
            AppLogoView(size: 44).opacity(0.9)

            Text("No games right now")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(suggestions.isEmpty
                 ? "Nothing scheduled. Add more leagues in Settings."
                 : "These leagues are playing now:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !suggestions.isEmpty {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(suggestions, id: \.id) { league in
                        Button {
                            controller.enableSuggestedLeague(league)
                        } label: {
                            Label("Add \(league.displayName)", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
            }

            Button("Open Settings") { controller.openSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }

    /// Cold-launch placeholder: skeleton rows matching the real row shape so the
    /// popup never flashes an empty state before the first fetch resolves.
    private var loadingState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ForEach(0..<3, id: \.self) { _ in skeletonRow }
            HStack(spacing: Theme.Spacing.md) {
                ProgressView().controlSize(.small)
                Text("Loading scores…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .accessibilityLabel(Text("Loading scores"))
    }

    private var skeletonRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            skeleton(width: 30, height: 10)
            VStack(spacing: 6) {
                skeleton(width: .infinity, height: 12)
                skeleton(width: .infinity, height: 12)
            }
        }
        .padding(.vertical, Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.lg)
        .background(Theme.rowFill, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    private func skeleton(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .frame(maxWidth: width == .infinity ? .infinity : width)
            .frame(height: height)
    }

    // MARK: - Quick Actions

    private var quickActionsFooter: some View {
        HStack(spacing: Theme.Spacing.xs) {
            quickAction("arrow.clockwise", "Refresh", spinning: controller.isRefreshing) {
                controller.refresh()
            }
            Spacer()
            moreMenu
        }
    }

    /// Low-frequency actions (updates, quit) folded behind one overflow control so
    /// the footer reads as a single primary action (Refresh) instead of a button row.
    private var moreMenu: some View {
        Menu {
            Button("Check for Updates…") { controller.checkForUpdates() }
            Divider()
            Button("Quit StatBar") { controller.quitApp() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private func quickAction(_ symbol: String, _ help: String, spinning: Bool = false,
                             tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: spinning)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Context line

    /// Secondary context line for the focused game (period / half text).
    private func contextStat(for match: Match) -> String? {
        match.detail.isEmpty ? nil : match.detail
    }
}
