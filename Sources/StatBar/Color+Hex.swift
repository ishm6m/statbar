import SwiftUI

extension Color {
    /// Builds a `Color` from an ESPN-style hex string (`"0b162a"`, optionally
    /// `#`-prefixed; 6 or 8 hex digits). Returns nil for anything malformed so
    /// callers fall back to a neutral default rather than a wrong color. The
    /// feed gives team colors without an alpha channel; 8-digit RRGGBBAA is
    /// accepted defensively in case that ever changes.
    init?(espnHex raw: String) {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16) else { return nil }

        let r, g, b, a: Double
        if hex.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
