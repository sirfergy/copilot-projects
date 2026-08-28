import Foundation

public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case waiting
}
