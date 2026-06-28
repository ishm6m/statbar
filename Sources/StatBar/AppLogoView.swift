import AppKit
import SwiftUI

/// The StatBar logo, drawn from the app's own bundled icon (`AppIcon.icns`) —
/// the single source of truth for branding. No second copy of the artwork is
/// bundled or referenced; this reads `NSApp.applicationIconImage`, so the icon
/// shown in Finder/Dock and the one shown in-app can never drift apart.
///
/// Used for branding surfaces (onboarding, Settings header, empty states) — NOT
/// the menu bar, which stays score-first by design.
struct AppLogoView: View {
    var size: CGFloat
    var cornerRadius: CGFloat?

    init(size: CGFloat = 64, cornerRadius: CGFloat? = nil) {
        self.size = size
        self.cornerRadius = cornerRadius
    }

    /// The live app icon. `applicationIconImage` is populated from the bundle's
    /// `CFBundleIconFile` once the app is running.
    private var icon: NSImage { NSApp.applicationIconImage }

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            // The artwork already carries its own rounded-rect shape; an optional
            // extra clip is offered for surfaces that want a tighter radius.
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? 0, style: .continuous))
            .accessibilityLabel(Text("StatBar"))
    }
}
