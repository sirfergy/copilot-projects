import Foundation
import CopilotProjectsProtocol

public typealias AppDeepLink = CopilotProjectsProtocol.AppDeepLink

public extension AppDeepLink {
    var focusRequest: ControlRequest {
        var request = ControlRequest(command: "focus")
        request.projectId = projectId
        request.sessionId = sessionId
        return request
    }

    static func parentApplicationURL(forHelperBundleURL helperURL: URL) -> URL? {
        let helpersDirectory = helperURL.deletingLastPathComponent()
        guard helpersDirectory.lastPathComponent == "Helpers" else { return nil }
        let contentsDirectory = helpersDirectory.deletingLastPathComponent()
        guard contentsDirectory.lastPathComponent == "Contents" else { return nil }
        let applicationURL = contentsDirectory.deletingLastPathComponent()
        guard applicationURL.pathExtension == "app" else { return nil }
        return applicationURL
    }
}
