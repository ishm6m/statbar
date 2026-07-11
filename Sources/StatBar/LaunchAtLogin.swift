import ServiceManagement
import SwiftUI

/// Launch-at-login via the native `SMAppService` API (macOS 13+). These are
/// the few lines the old LaunchAtLogin-Modern dependency wrapped, kept under
/// the same names so call sites read unchanged.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.lifecycle.error("Launch at login toggle failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    struct Toggle: View {
        private let title: String
        @State private var isEnabled = LaunchAtLogin.isEnabled

        init(_ title: String) { self.title = title }

        var body: some View {
            SwiftUI.Toggle(title, isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    LaunchAtLogin.isEnabled = newValue
                    // Read back so a failed register/unregister reverts the UI.
                    isEnabled = LaunchAtLogin.isEnabled
                }
            ))
        }
    }
}
