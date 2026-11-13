import CopilotProjectsCore
@testable import CopilotProjectsHost

/// The record the status hooks still write. The app no longer reads it, so only
/// the hook script's own tests decode it.
struct InputWaitContext: Codable, Equatable {
    let senderSessionId: String
    let rootSessionId: String
    let conversationEpoch: String
}

struct SessionStatusRecord: Codable, Equatable {
    let schemaVersion: Int
    let status: SessionStatus
    let statusTimestamp: Int64
    let promptStatusTimestamp: Int64
    let inputWait: InputWaitContext?

    init(
        status: SessionStatus,
        statusTimestamp: Int64,
        promptStatusTimestamp: Int64,
        inputWait: InputWaitContext? = nil
    ) {
        schemaVersion = 1
        self.status = status
        self.statusTimestamp = statusTimestamp
        self.promptStatusTimestamp = promptStatusTimestamp
        self.inputWait = inputWait
    }
}
