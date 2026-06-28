import AppKit
import SwiftUI

/// Hosts SettingsView in a standalone NSWindow, separate from the menu bar
/// popover (PRD Session 5: "Open SettingsView in a separate NSWindow").
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let viewModel = SettingsViewModel()

    /// Refresh the menu bar after a setting changes.
    var onPreferencesChanged: (() -> Void)? {
        get { viewModel.onPreferencesChanged }
        set { viewModel.onPreferencesChanged = newValue }
    }

    /// Set by AppDelegate to trigger an update check. Defaults to a no-op
    /// so the window is safe to present before wiring.
    var onCheckForUpdates: () -> Void = {}

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = SettingsView(viewModel: self.viewModel, onCheckForUpdates: self.onCheckForUpdates)
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "StatBar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setContentSize(NSSize(width: 480, height: 580))

        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
