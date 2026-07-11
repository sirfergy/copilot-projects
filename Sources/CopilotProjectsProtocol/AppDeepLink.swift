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
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ) else {
            return nil
        }

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
}
