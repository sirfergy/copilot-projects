import Foundation
import CopilotProjectsProtocol

/// Lifecycle status a session can report. Mirrors cmux's running/idle/needsInput.
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case waiting   // waiting for user input
}

public typealias StatusNotificationKind =
    CopilotProjectsProtocol.StatusNotificationKind

/// A single request sent over the control socket as one line of JSON.
public struct ControlRequest: Codable, Sendable {
    public var command: String
    public var projectId: String?
    public var sessionId: String?
    public var status: String?
    public var timestamp: Int64?
    public var source: String?
    public var copilotSessionId: String?
    public var text: String?
    public var notification: StatusNotificationKind?
    public var title: String?
    public var body: String?
    public var name: String?
    public var cwd: String?
    public var path: String?
    public var action: String?

    public init(command: String) {
        self.command = command
    }
}

/// The response sent back over the control socket as one line of JSON.
public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var text: String?

    public init(ok: Bool, error: String? = nil, text: String? = nil) {
        self.ok = ok
        self.error = error
        self.text = text
    }

    public static func success(_ text: String? = nil) -> ControlResponse {
        ControlResponse(ok: true, text: text)
    }

    public static func failure(_ error: String) -> ControlResponse {
        ControlResponse(ok: false, error: error)
    }
}

public enum Wire {
    /// Encodes a value to a single line of JSON terminated by `\n`.
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
