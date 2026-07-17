<div align="center">

<img src="docs/images/icon.png" width="128" alt="StatBar icon">

# StatBar

**Live football scores in your macOS menu bar. Free and open source.**

[![Download](https://img.shields.io/github/v/release/ishm6m/statbar?label=Download&style=for-the-badge)](https://github.com/ishm6m/statbar/releases/latest)

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://github.com/ishm6m/statbar/releases/latest)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://swift.org)
[![License: MIT](https://img.shields.io/github/license/ishm6m/statbar)](LICENSE)
[![Stars](https://img.shields.io/github/stars/ishm6m/statbar?style=flat)](https://github.com/ishm6m/statbar/stargazers)

<img src="docs/images/hero.png" width="720" alt="StatBar showing live football scores in the macOS menu bar">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/leagues-bar-dark.png">
  <img src="docs/images/leagues-bar-light.png" width="720" alt="Premier League, La Liga, Serie A, Bundesliga, Ligue 1, MLS, EFL Championship, Primeira Liga, Eredivisie, Liga MX, Brasileirão, NWSL, Champions League, Europa League, Conference League, and FIFA World Cup logos">
</picture>

</div>

StatBar is a lightweight menu-bar agent that puts live scores from the world's
top football leagues and competitions a glance away, with no window to switch to
and no browser tab. Tap a match for the full story: a complete timeline of goals,
cards, and substitutions.

## Features

- **Always in reach.** Scores live in the menu bar, updated in real time.
- **Smart Focus.** Surfaces the game that matters right now (the close one, the
  one in overtime, the team you follow).
- **Follow your team.** The menu bar tracks your team: live score, then full-time
  result, then next fixture.
- **Real crests & flags.** Official logos fetched live, clean monogram fallback.
- **Quiet by design.** Refreshes fast when games are live, sleeps when they're
  not. Native, lightweight, battery-friendly.
- **Notifications.** Match starting, goals, and final scores.

<table>
  <tr>
    <td width="50%"><img src="docs/images/popup.png" alt="StatBar popup listing live matches"></td>
    <td width="50%"><img src="docs/images/soccer-detail.png" alt="Football match timeline with goals, cards, and subs"></td>
  </tr>
  <tr>
    <td align="center"><b>Every match, one glance</b></td>
    <td align="center"><b>Full match timeline</b></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/stats.png" alt="Match stats: fouls, cards, possession, and shots"></td>
    <td width="50%"><img src="docs/images/settings.png" alt="StatBar settings with menu-bar style and league toggles"></td>
  </tr>
  <tr>
    <td align="center"><b>Stats, lineups, and tables</b></td>
    <td align="center"><b>Your leagues, your style</b></td>
  </tr>
</table>

**Leagues:** Premier League, La Liga, Serie A, Bundesliga, Ligue 1, MLS, EFL
Championship, Primeira Liga, Eredivisie, Liga MX, Brasileirão, NWSL.
**Cups:** Champions League, Europa League, Conference League, FIFA World Cup,
FIFA Women's World Cup.

Data comes from ESPN's public endpoints. Not affiliated with any league or
broadcaster.

## Install

Download the latest `StatBar.app.zip` from
[Releases](https://github.com/ishm6m/statbar/releases/latest), unzip, and drag
**StatBar.app** to `/Applications`.

> macOS 13 (Ventura) or later.

The build is ad-hoc signed (no Apple Developer ID), so on first launch macOS
will warn it's from an unidentified developer. Right-click the app → **Open**,
or allow it under **System Settings → Privacy & Security**.

## Build from source

Requires a recent Swift toolchain (Xcode 16 / Swift 6).

```sh
swift build -c release   # build the binary
make                     # build the StatBar.app bundle (ad-hoc codesigned)
```

The bundle lands in `build/`. `make` runs the release build and packages it.

## Project layout

- `Sources/StatBar/`: the app (SwiftUI + AppKit menu-bar agent).
- `Tests/`: unit tests (`swift test`).
- `Resources/`: assets bundled into the app.
- `site/`: marketing landing page (Next.js).
- `version.json`: update manifest read by the in-app update checker.

## Author

Built by Shahriyar Ishmam.

- Website: https://ishmam-os.vercel.app/
- LinkedIn: https://www.linkedin.com/in/shahriyar-ishmam/

## License

[MIT](LICENSE) © 2026 StatBar contributors.
