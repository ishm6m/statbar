import SwiftUI

/// A team's page: recent results, upcoming fixtures, and the league table with
/// the team highlighted. Built from ESPN's team-schedule endpoint plus league
/// standings (`APIService.fetchTeamPage`). Reached by tapping a team in the
/// match-detail header; sits above the detail scene in the popup's back stack.
struct TeamPage: Equatable, Sendable {
    /// Display name the page is for, as the open match spelled it.
    let team: String
    /// Played games, newest-first.
    let results: [TeamGame]
    /// Upcoming fixtures, soonest-first.
    let fixtures: [TeamGame]
    /// League table, the team's row flagged `isMatchTeam`.
    let standings: [StandingsRow]

    var isEmpty: Bool { results.isEmpty && fixtures.isEmpty && standings.isEmpty }
}

/// What the controller needs to open and render a team page: the team's identity
/// (for the schedule fetch and the header) before the page data lands.
struct TeamPageContext: Equatable {
    let teamID: String
    let teamName: String
    let leagueID: String
    let sport: Sport
    let logoURL: String?
}

/// One game on a team's schedule — a played result or an upcoming fixture.
struct TeamGame: Identifiable, Equatable, Sendable {
    let id: String
    /// Short date, e.g. "14 May 26". Empty when the feed omits it.
    let date: String
    /// Opponent abbreviation (or name), e.g. "CHE".
    let opponent: String
    /// "vs" (home) or "@" (away).
    let homeAway: String
    /// Score line in this team's order, e.g. "2–1". Empty for upcoming games.
    let line: String
    let outcome: FormResult.Outcome
    let played: Bool
    let kickoff: Date?
}

struct TeamPageScene: View {
    @ObservedObject var controller: PopupController
    let context: TeamPageContext

    private var page: TeamPage? { controller.teamPageData }
    private let contentHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            backBar
            header
            Divider()
            content
                .frame(height: contentHeight)
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: - Back bar

    private var backBar: some View {
        Button { controller.closeTeamPage() } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.caption.weight(.bold))
                Text("Back").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to the match")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            LogoView(teamID: context.teamName, sport: context.sport, league: context.leagueID,
                     label: context.teamName, size: 26, overrideURL: context.logoURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(context.teamName)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                if let line = recordLine {
                    Text(line).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 4)
        }
    }

    /// Compact season line pulled from the team's own standings row, when present:
    /// "#4 · P30 · 18-7-5 · 61 pts".
    private var recordLine: String? {
        guard let row = page?.standings.first(where: \.isMatchTeam) else { return nil }
        var parts: [String] = []
        if !row.rank.isEmpty { parts.append("#\(row.rank)") }
        if !row.played.isEmpty { parts.append("P\(row.played)") }
        if !row.record.isEmpty { parts.append(row.record) }
        if !row.points.isEmpty { parts.append("\(row.points) pts") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if controller.teamPageLoading && page == nil {
            centered {
                ProgressView().controlSize(.small)
                Text("Loading team…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let page, !page.isEmpty {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if !page.fixtures.isEmpty {
                        sectionHeader("UPCOMING")
                        ForEach(page.fixtures.prefix(6)) { fixtureRow($0) }
                    }
                    if !page.results.isEmpty {
                        sectionHeader("RECENT")
                        ForEach(page.results.prefix(6)) { resultRow($0) }
                    }
                    if !page.standings.isEmpty {
                        sectionHeader("STANDINGS")
                        standingsHeaderRow
                        ForEach(page.standings) { standingsRow($0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            centered {
                Image(systemName: "person.2").font(.title2).foregroundStyle(.tertiary)
                Text("No team data").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(.tertiary).padding(.top, 2)
    }

    // MARK: - Rows

    private func fixtureRow(_ g: TeamGame) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(g.homeAway).font(.caption2).foregroundStyle(.tertiary).frame(width: 18, alignment: .leading)
            Text(g.opponent).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(g.date).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 1)
    }

    private func resultRow(_ g: TeamGame) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(outcomeLetter(g.outcome))
                .font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(outcomeColor(g.outcome), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(g.homeAway).font(.caption2).foregroundStyle(.tertiary).frame(width: 18, alignment: .leading)
            Text(g.opponent).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(g.line).font(.caption.weight(.bold)).monospacedDigit()
            Text(g.date).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    private var standingsHeaderRow: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 20, alignment: .leading)
            Text("Team").frame(maxWidth: .infinity, alignment: .leading)
            Text("P").frame(width: 26, alignment: .trailing)
            Text("GD").frame(width: 34, alignment: .trailing)
            Text("Pts").frame(width: 30, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
    }

    private func standingsRow(_ row: StandingsRow) -> some View {
        HStack(spacing: 0) {
            Text(row.rank).frame(width: 20, alignment: .leading).foregroundStyle(.secondary)
            Text(row.team).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .fontWeight(row.isMatchTeam ? .bold : .regular)
            Text(row.played).frame(width: 26, alignment: .trailing)
            Text(row.goalDiff).frame(width: 34, alignment: .trailing)
            Text(row.points).fontWeight(.semibold).frame(width: 30, alignment: .trailing)
        }
        .font(.system(size: 10)).monospacedDigit()
        .padding(.vertical, 2).padding(.horizontal, 4)
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

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: Theme.Spacing.sm) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
