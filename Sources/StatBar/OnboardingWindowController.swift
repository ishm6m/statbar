import AppKit
import SwiftUI

/// Hosts `OnboardingView` in a centered standalone window for first launch.
/// On completion it closes the window, requests notification permission when
/// the user opted in, and notifies the app so the menu bar + popup repaint
/// with the freshly chosen preferences.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    /// Called after onboarding finishes (window already closed).
    var onFinished: (() -> Void)?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = OnboardingView { [weak self] requestNotifications in
            self?.complete(requestNotifications: requestNotifications)
        }
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to StatBar"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setContentSize(NSSize(width: 480, height: 560))
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func complete(requestNotifications: Bool) {
        if requestNotifications {
            NotificationService.shared.requestPermissionIfNeeded()
        }
        window?.close()
        window = nil
        onFinished?()
    }
}
