import Foundation

public struct AppDeepLink: Equatable, Sendable {
    public let projectId: String?
    public let sessionId: String?

    public init(projectId: String?, sessionId: String?) {
        self.projectId = projectId
        self.sessionId = sessionId
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "copilot-projects",
              url.host?.lowercased() == "focus",
              url.path.isEmpty || url.path == "/",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        func firstValue(_ name: String) -> String? {
            components.queryItems?
                .lazy
                .filter { $0.name == name }
                .compactMap(\.value)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }

        projectId = firstValue("project")
        sessionId = firstValue("session")
        guard projectId != nil || sessionId != nil else { return nil }
    }

    public var focusRequest: ControlRequest {
        var request = ControlRequest(command: "focus")
        request.projectId = projectId
        request.sessionId = sessionId
        return request
    }

    public static func parentApplicationURL(forHelperBundleURL helperURL: URL) -> URL? {
        let helpersDirectory = helperURL.deletingLastPathComponent()
        guard helpersDirectory.lastPathComponent == "Helpers" else { return nil }
        let contentsDirectory = helpersDirectory.deletingLastPathComponent()
        guard contentsDirectory.lastPathComponent == "Contents" else { return nil }
        let applicationURL = contentsDirectory.deletingLastPathComponent()
        guard applicationURL.pathExtension == "app" else { return nil }
        return applicationURL
    }
}
