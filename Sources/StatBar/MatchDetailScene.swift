import SwiftUI
import AppKit

/// The expanded match view: a back bar, the live score header, then a tabbed
/// deep-dive — Timeline (key events + minute commentary), Stats (side-by-side
/// team stats), Lineups (formations + XI/bench), and Info (venue/referee).
/// Reached by clicking the menu bar (jumps straight here for the pinned game)
/// or tapping a game in the list.
///
/// The tab content lives in a fixed-height internal scroller on purpose: the
/// popup panel measures its height once, at open, but the detail is fetched async
/// a beat later — a fixed area keeps the panel correctly sized whether the data
/// has landed or not, and lets a long tab scroll without resizing the panel.
struct MatchDetailScene: View {
    @ObservedObject var controller: PopupController
    let match: Match
    @State private var selectedTab: DetailTab = .timeline

    /// Prefer the controller's live snapshot (refreshed on each poll) so the
    /// score header updates while the scene is open.
    private var live: Match { controller.detailMatch ?? match }
    private var detail: MatchDetail? { controller.detailData }

    private let contentHeight: CGFloat = 300

    enum DetailTab: String, CaseIterable {
        case timeline = "Timeline"
        case stats = "Stats"
        case lineups = "Lineups"
        case shots = "Shots"
        case table = "Table"
        case odds = "Odds"
        case info = "Info"
    }

    /// Tabs that actually have content, in fixed order. Empty tabs are hidden so
    /// there is never a dead control (PRD §7).
    private var availableTabs: [DetailTab] {
        guard let d = detail else { return [] }
        var tabs: [DetailTab] = []
        if !d.events.isEmpty || !d.commentary.isEmpty { tabs.append(.timeline) }
        if !d.teamStats.isEmpty { tabs.append(.stats) }
        if d.homeLineup != nil || d.awayLineup != nil { tabs.append(.lineups) }
        if !d.shots.isEmpty { tabs.append(.shots) }
        if !d.standings.isEmpty || !d.form.isEmpty || !d.headToHead.isEmpty { tabs.append(.table) }
        if d.odds != nil { tabs.append(.odds) }
        if !d.info.isEmpty { tabs.append(.info) }
        return tabs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            backBar
            scoreHeader
            Divider()
            tabbedContent
                .frame(height: contentHeight)
        }
        .padding(Theme.Spacing.lg)
        .onChange(of: availableTabs) { tabs in
            if !tabs.contains(selectedTab), let first = tabs.first { selectedTab = first }
        }
    }

    // MARK: - Back bar

    private var backBar: some View {
        Button {
            controller.closeDetail()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
                Text("All games")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to the game list")
    }

    // MARK: - Score header

    private var scoreHeader: some View {
        VStack(spacing: Theme.Spacing.sm) {
            teamRow(name: live.homeTeam, score: live.homeScore, logo: live.homeLogo, home: true)
            teamRow(name: live.awayTeam, score: live.awayScore, logo: live.awayLogo, home: false)
            HStack(spacing: 4) {
                if live.isLive { LiveDot(size: 5) }
                Text(stateText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(live.isLive ? Theme.live : .secondary)
                if let stage = live.stage {
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                    Text(stage)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func teamRow(name: String, score: Int, logo: String?, home: Bool) -> some View {
        let tappable = controller.hasTeamPage(live, home: home)
        return Button {
            if tappable { controller.openTeamPage(live, home: home) }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                LogoView(teamID: name, sport: live.sport, league: live.league,
                         label: name, size: 20, overrideURL: logo)
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if live.isLive || live.isFinal {
                    Text("\(score)")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
        .help(tappable ? "View \(name)’s fixtures & form" : "")
    }

    private var stateText: String {
        if live.isFinal { return MatchFocus.isOvertime(live) ? "AET" : "FT" }
        if live.isLive { return live.gameClock.isEmpty ? "Live" : live.gameClock }
        return live.scheduledTimeText
    }

    // MARK: - Tabbed content

    @ViewBuilder
    private var tabbedContent: some View {
        if controller.detailLoading && detail == nil {
            centered {
                ProgressView().controlSize(.small)
                Text("Loading match detail…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if availableTabs.isEmpty {
            centered {
                Image(systemName: "soccerball")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(live.isLive ? "No match detail yet" : "No match detail recorded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Full coverage on ESPN")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if availableTabs.count > 1 {
                    tabStrip
                }
                ScrollView(.vertical, showsIndicators: true) {
                    tabBody(availableTabs.contains(selectedTab) ? selectedTab : (availableTabs.first ?? .timeline))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Horizontally-scrollable pill tab bar. A `.segmented` Picker can't fit the
    /// six/seven detail tabs in the 320pt popup — "Timeline" truncated to "…line"
    /// and the row overflowed. A scrolling chip row never truncates at any tab
    /// count and reads like Stocks / News. The selected chip auto-centers.
    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(availableTabs, id: \.self) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.bottom, 2)
            }
            .onChange(of: selectedTab) { tab in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(tab, anchor: .center) }
            }
        }
    }

    private func tabChip(_ tab: DetailTab) -> some View {
        let selected = tab == selectedTab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            Text(tab.rawValue)
                .font(.caption.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs + 1)
                .background(
                    Capsule().fill(selected ? Color.accentColor : Theme.rowFill)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(tab)
    }

    @ViewBuilder
    private func tabBody(_ tab: DetailTab) -> some View {
        switch tab {
        case .timeline: timelineTab
        case .stats: statsTab
        case .lineups: lineupsTab
        case .shots: shotsTab
        case .table: tableTab
        case .odds: oddsTab
        case .info: infoTab
        }
    }

    // MARK: - Timeline tab

    @ViewBuilder
    private var timelineTab: some View {
        let events = detail?.events ?? []
        let commentary = detail?.commentary ?? []
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(events) { eventRow($0) }
            if !commentary.isEmpty {
                if !events.isEmpty {
                    Text("COMMENTARY")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, Theme.Spacing.sm)
                }
                ForEach(commentary) { commentaryRow($0) }
            }
        }
    }

    private func eventRow(_ event: KeyEvent) -> some View {
        let emphasised = event.kind == .goal || event.kind == .score
        return HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text(event.clock.isEmpty ? "·" : event.clock)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Image(systemName: event.kind.symbol)
                .font(.caption)
                .foregroundStyle(glyphTint(event.kind))
                .frame(width: 16)
            Text(event.text)
                .font(.caption)
                .foregroundStyle(emphasised ? .primary : .secondary)
                .fontWeight(emphasised ? .semibold : .regular)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
    }

    private func commentaryRow(_ item: CommentaryItem) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text(item.clock.isEmpty ? "·" : item.clock)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)
            Text(item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 1)
    }

    private func glyphTint(_ kind: KeyEvent.Kind) -> Color {
        switch kind {
        case .goal, .score: return Color.accentColor
        case .yellowCard: return .yellow
        case .redCard: return .red
        case .substitution: return .green
        case .other: return .secondary
        }
    }

    // MARK: - Stats tab

    @ViewBuilder
    private var statsTab: some View {
        let stats = detail?.teamStats ?? []
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(live.homeTeam).font(.caption2.weight(.bold))
                Spacer()
                Text(live.awayTeam).font(.caption2.weight(.bold))
            }
            .foregroundStyle(.secondary)
            ForEach(stats) { statRow($0) }
        }
    }

    private func statRow(_ stat: TeamStat) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(stat.home)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Text(stat.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(stat.away)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            if let split = stat.split {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(2, geo.size.width * split.home - 1))
                        Capsule().fill(Color.secondary.opacity(0.4))
                            .frame(width: max(2, geo.size.width * split.away - 1))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Lineups tab

    @ViewBuilder
    private var lineupsTab: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let home = detail?.homeLineup {
                lineupSection(team: live.homeTeam, lineup: home)
            }
            if let away = detail?.awayLineup {
                lineupSection(team: live.awayTeam, lineup: away)
            }
        }
    }

    private func lineupSection(team: String, lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(team).font(.caption.weight(.bold))
                if !lineup.formation.isEmpty {
                    Text(lineup.formation)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            ForEach(lineup.starters) { playerRow($0) }
            if !lineup.subs.isEmpty {
                Text("BENCH")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                ForEach(lineup.subs) { playerRow($0) }
            }
        }
    }

    private func playerRow(_ p: LineupPlayer) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(p.jersey.isEmpty ? "–" : p.jersey)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(p.name)
                .font(.caption)
                .lineLimit(1)
            if p.subbedOut {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
            }
            if p.subbedIn {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
            }
            Spacer(minLength: 4)
            if !p.position.isEmpty {
                Text(p.position)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Shots tab (team shot funnel + top shooters)

    @ViewBuilder
    private var shotsTab: some View {
        let teamShots = detail?.shots.teamShots ?? []
        let shooters = detail?.shots.shooters ?? []
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if !teamShots.isEmpty {
                HStack {
                    Text(live.homeTeam).font(.caption2.weight(.bold))
                    Spacer()
                    Text(live.awayTeam).font(.caption2.weight(.bold))
                }
                .foregroundStyle(.secondary)
                ForEach(teamShots) { statRow($0) }
            }
            if !shooters.isEmpty {
                sectionHeader("TOP SHOTS")
                shootersHeaderRow
                ForEach(shooters) { shooterRow($0) }
            }
        }
    }

    /// Column headings for the shooters list.
    private var shootersHeaderRow: some View {
        HStack(spacing: 0) {
            Text("Player").frame(maxWidth: .infinity, alignment: .leading)
            Text("Sh").frame(width: 28, alignment: .trailing)
            Text("SOG").frame(width: 36, alignment: .trailing)
            Text("G").frame(width: 24, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.tertiary)
    }

    private func shooterRow(_ s: Shooter) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(s.name).font(.caption).lineLimit(1)
                if !s.team.isEmpty {
                    Text(s.team)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(s.shots)").frame(width: 28, alignment: .trailing)
            Text("\(s.onTarget)").frame(width: 36, alignment: .trailing)
            Text("\(s.goals)")
                .fontWeight(s.goals > 0 ? .bold : .regular)
                .foregroundStyle(s.goals > 0 ? Color.accentColor : .primary)
                .frame(width: 24, alignment: .trailing)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.vertical, 1)
    }

    // MARK: - Table tab (form + head-to-head + standings)

    @ViewBuilder
    private var tableTab: some View {
        let form = detail?.form ?? []
        let h2h = detail?.headToHead ?? []
        let standings = detail?.standings ?? []
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if !form.isEmpty {
                sectionHeader("RECENT FORM")
                ForEach(form) { formRow($0) }
            }
            if !h2h.isEmpty {
                sectionHeader("HEAD-TO-HEAD")
                ForEach(h2h) { h2hRow($0) }
            }
            if !standings.isEmpty {
                sectionHeader("STANDINGS")
                standingsHeaderRow
                ForEach(standings) { standingsRow($0) }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    /// A team's last-five strip: abbreviation then newest-first W/D/L chips.
    private func formRow(_ guide: FormGuide) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(guide.team)
                .font(.caption.weight(.bold))
                .frame(width: 44, alignment: .leading)
            ForEach(guide.results) { result in
                Text(outcomeLetter(result.outcome))
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(outcomeColor(result.outcome), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .help(result.summary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 1)
    }

    private func h2hRow(_ game: HeadToHeadGame) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(outcomeColor(game.outcome))
                .frame(width: 6, height: 6)
            Text(game.line)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(game.date)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 1)
    }

    /// Column headings for the league table.
    private var standingsHeaderRow: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 20, alignment: .leading)
            Text("Team").frame(maxWidth: .infinity, alignment: .leading)
            Text("P").frame(width: 26, alignment: .trailing)
            Text("W-D-L").frame(width: 52, alignment: .trailing)
            Text("GD").frame(width: 34, alignment: .trailing)
            Text("Pts").frame(width: 30, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.tertiary)
    }

    private func standingsRow(_ row: StandingsRow) -> some View {
        HStack(spacing: 0) {
            Text(row.rank)
                .frame(width: 20, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(row.team)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fontWeight(row.isMatchTeam ? .bold : .regular)
            Text(row.played).frame(width: 26, alignment: .trailing)
            Text(row.record).frame(width: 52, alignment: .trailing)
            Text(row.goalDiff).frame(width: 34, alignment: .trailing)
            Text(row.points)
                .fontWeight(.semibold)
                .frame(width: 30, alignment: .trailing)
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            row.isMatchTeam ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
    }

    private func outcomeLetter(_ o: FormResult.Outcome) -> String {
        switch o {
        case .win: return "W"
        case .draw: return "D"
        case .loss: return "L"
        case .unknown: return "–"
        }
    }

    private func outcomeColor(_ o: FormResult.Outcome) -> Color {
        switch o {
        case .win: return .green
        case .draw: return .gray
        case .loss: return .red
        case .unknown: return .secondary
        }
    }

    // MARK: - Odds tab (moneyline 3-way + spread + over/under)

    @ViewBuilder
    private var oddsTab: some View {
        if let odds = detail?.odds {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionHeader("MONEYLINE")
                oddsRow(odds.homeTeam, odds.homeMoneyline)
                if !odds.drawMoneyline.isEmpty {
                    oddsRow("Draw", odds.drawMoneyline)
                }
                oddsRow(odds.awayTeam, odds.awayMoneyline)

                if !odds.spread.isEmpty || !odds.overUnder.isEmpty {
                    sectionHeader("LINES")
                    if !odds.spread.isEmpty {
                        oddsLine("Spread", odds.spread)
                    }
                    if !odds.overUnder.isEmpty {
                        oddsLine("Over / Under", odds.overUnder)
                    }
                }

                if !odds.provider.isEmpty {
                    Text("Odds via \(odds.provider)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// One moneyline row: team (or "Draw") on the left, American price on the
    /// right. An empty price reads as "—" rather than a blank gap.
    private func oddsRow(_ label: String, _ price: String) -> some View {
        HStack {
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(price.isEmpty ? "—" : price)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(price.hasPrefix("-") ? .primary : Color.accentColor)
        }
        .padding(.vertical, 1)
    }

    /// A non-moneyline market line (spread / over-under): label left, value right.
    private func oddsLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 1)
    }

    // MARK: - Info tab

    @ViewBuilder
    private var infoTab: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(detail?.info ?? []) { item in
                HStack(alignment: .top) {
                    Text(item.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(item.value)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }
            }
        }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: Theme.Spacing.sm) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
