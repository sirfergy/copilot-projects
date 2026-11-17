import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol

extension AppModel {
    /// `queued-prompts`: lists a session's pending prompts as its tracker publishes them, or
    /// sends one now or takes one back and answers with the tracker's receipt.
    func queuedPromptsCommand(
        _ request: ControlRequest, pollInterval: Duration = .milliseconds(500)
    ) async -> ControlResponse {
        let sessionId = request.sessionId ?? ""
        if let refusal = automationRefusal(sessionId: sessionId, projectId: request.projectId) { return refusal }
        // A parked session is refused here: submitting an action to one resumes it.
        guard parkedState(sessionId) == nil else {
            return .failure("The session is parked, so it has no queued prompts.", code: "parked")
        }
        guard let action = request.action else {
            let adapter = CLIOperationAdapter(
                activityDirectory: agentActivityDirectory, resumeMarkerDirectory: resumeMarkerDirectory)
            guard let workflow = adapter.loadFreshSnapshot(sessionId: sessionId, now: { Date() })?.workflow,
                  let json = try? JSONEncoder().encode(workflow.pendingMessages ?? []) else {
                return .failure("the session's tracker is not ready", code: "busy")
            }
            return .success(String(decoding: json, as: UTF8.self))
        }
        let kinds: [String: RemoteSessionActionKind] = ["send-now": .queueSendNow, "remove": .queueRemove]
        guard let kind = kinds[action] else {
            return .failure("queued-prompts takes send-now or remove", code: "bad-request")
        }
        let result = await performLocalSessionAction(
            sessionId: sessionId, action: RemoteSessionAction(kind: kind, messageId: request.messageId),
            pollInterval: pollInterval
        )
        return result.state == .applied
            ? .success(code: "applied")
            : .failure(result.message ?? "Copilot did not apply this action.", code: result.state.rawValue)
    }
}
