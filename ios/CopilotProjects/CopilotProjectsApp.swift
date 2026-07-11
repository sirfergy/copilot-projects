import SwiftUI

@main
struct CopilotProjectsApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @State private var authentication: CloudflareSession
    @State private var client: RemoteClient
    private let notifications = NotificationCoordinator.shared

    init() {
        let authentication = CloudflareSession()
        _authentication = State(initialValue: authentication)
        _client = State(initialValue: RemoteClient(authentication: authentication))
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                authentication: authentication,
                client: client,
                notifications: notifications
            )
        }
    }
}
