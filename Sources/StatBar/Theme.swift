import SwiftUI

/// Single source of truth for StatBar's look — spacing, corner radii, typography
/// and the handful of surface treatments every screen shares. Before this, each
/// view hand-rolled its own padding/fonts/backgrounds, so the popup, onboarding,
/// settings drifted apart. Centralizing them keeps the dense
/// scoreboard, first-run, and settings visually of a piece.
enum Theme {
    /// 4-pt rhythm. Use these instead of magic numbers so vertical/horizontal
    /// spacing stays consistent across surfaces.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
    }

    /// Corner radii, leanest (a list row) → largest (the popup shell).
    enum Radius {
        static let row: CGFloat = 8
        static let card: CGFloat = 12
        static let popup: CGFloat = 14
    }

    // MARK: - Color

    /// The shared "live" green — matches `LiveDot` so the pulsing dot, live
    /// scores and clocks all read as the same cue.
    static let live = Color.green

    /// Hairline used for card borders and row separators on the material
    /// background — barely-there, just enough to define an edge.
    static let hairline = Color.primary.opacity(0.08)

    /// Faint fill behind an unselected row / inert chip.
    static let rowFill = Color.secondary.opacity(0.08)

    /// Fill behind the selected/pinned row, tinted with the accent.
    static let rowFillSelected = Color.accentColor.opacity(0.14)

    // MARK: - Typography

    /// The big rounded, monospaced scoreline used in the hero/focused row.
    static func score(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }

    /// A team abbreviation / name token.
    static let team = Font.system(size: 12, weight: .semibold)

    /// An uppercased section eyebrow ("GAMES", "LEAGUES").
    static let eyebrow = Font.caption2.weight(.semibold)
}

// MARK: - Surface treatments

extension View {
    /// Standard card: rounded rect fill + hairline border. Used by Settings
    /// sections and onboarding panels so every grouped surface
    /// shares one shape.
    func statCard(padding: CGFloat = Theme.Spacing.lg, selected: Bool = false) -> some View {
        self
            .padding(padding)
            .background(selected ? Theme.rowFillSelected : Theme.rowFill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.4) : Theme.hairline)
            )
    }

    /// Liquid Glass (macOS 26+) on a *floating control* — the search field and
    /// league dropdown — falling back to the flat tinted fill below it.
    /// ponytail: glass is the nav/control layer only; score rows and the panel
    /// stay solid so dense numbers keep their legibility (no glass-on-glass).
    /// Plain (non-`.interactive()`) glass: `.interactive()` adds its own
    /// hit-testing layer and swallows clicks meant for the embedded TextField —
    /// it's for glass that *is* the control, not a container around one.
    @ViewBuilder
    func floatingGlass<S: Shape>(_ shape: S, fallback: Color = Theme.rowFill) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(fallback, in: shape)
        }
    }

    /// Prominent Liquid Glass on the primary CTA (macOS 26+), else the standard
    /// prominent button. One swap point so the primary action buttons match.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// A 3-pt brand-color edge pinned to the leading side of a scoreboard row —
    /// the primary "scan accent" that lets the eye find a game by team color.
    /// No-ops to a faint neutral edge when the feed carries no usable color.
    func brandEdge(_ hex: String?) -> some View {
        let color = hex.flatMap { Color(espnHex: $0) } ?? Color.secondary.opacity(0.25)
        return self
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(color)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
    }
}
