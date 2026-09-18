import Foundation

public enum RemoteProjectContract {
    public static let createPath = "projects/create"
    public static let maximumNameBytes = 200
    public static let errorCodeHeader = RemoteSessionContract.errorCodeHeader
    public static let persistenceUnavailableErrorCode =
        RemoteSessionContract.persistenceUnavailableErrorCode

    public static func normalizedName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= maximumNameBytes,
              name.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value)
              }) else {
            return nil
        }
        return name
    }
}

/// Creates a named group without starting a session. Retain the exact request
/// across retries; older gateways return 404 for the dedicated endpoint.
public struct RemoteCreateProjectRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let name: String

    public init(requestId: UUID, name: String) {
        self.requestId = requestId
        self.name = name
    }
}

public struct RemoteCreateProjectResponse: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let projectId: String

    public init(requestId: UUID, projectId: String) {
        self.requestId = requestId
        self.projectId = projectId
    }
}
