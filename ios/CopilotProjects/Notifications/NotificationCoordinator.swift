import Foundation
import Observation
import UIKit
import UserNotifications
import CopilotProjectsProtocol

@MainActor
@Observable
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    private(set) var deviceToken: String?
    private(set) var environment: CopilotProjectsProtocol.APNsEnvironment = {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }()
    var pendingDeepLink: AppDeepLink?

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) {
            granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func resumeRegistrationIfAuthorized() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func didRegister(deviceToken: Data) {
        NSLog(
            "Copilot Projects: registered APNs token (%d bytes, %@)",
            deviceToken.count,
            environment.rawValue
        )
        self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let projectID = info["projectId"] as? String
        let sessionID = info["sessionId"] as? String
        Task { @MainActor in
            self.pendingDeepLink = AppDeepLink(
                projectId: projectID,
                sessionId: sessionID
            )
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate =
            NotificationCoordinator.shared
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            NotificationCoordinator.shared.didRegister(deviceToken: deviceToken)
        }
    }
}
