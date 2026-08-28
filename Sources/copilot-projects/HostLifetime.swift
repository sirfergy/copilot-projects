import SwiftUI
import AppKit

enum HostLifetimePolicy {
    static let settingKey = "keepRunningAfterWindowClose"

    static func shouldTerminateAfterLastWindowClosed(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: settingKey)
    }
}

struct MainWindowContent: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView(model: appDelegate.model)
            .onAppear {
                let action = openWindow
                appDelegate.model.requestMainWindow = { action(id: "main") }
            }
    }
}

struct HostStatusMenu: View {
    @Binding var keepRunning: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Copilot Projects") { showMainWindow() }
        Toggle("Keep Running When Window Closes", isOn: Binding(
            get: { keepRunning },
            set: { enabled in
                keepRunning = enabled
                if !enabled { showMainWindow() }
            }
        ))
        Divider()
        Button("Quit Copilot Projects") { NSApp.terminate(nil) }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
