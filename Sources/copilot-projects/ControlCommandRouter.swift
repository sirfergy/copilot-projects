import Foundation
import CopilotProjectsCore

struct ControlCommandRouter {
    struct Actions {
        let listProjects: () -> String
        let listStatus: () -> String
        let setStatus: (SessionStatus, String?, ControlRequest) -> ControlResponse
        let notify: (String, String?, ControlRequest) -> ControlResponse
        let newProject: (ControlRequest) -> ControlResponse
        let newSession: (ControlRequest) -> ControlResponse
        let renameProject: (String, ControlRequest) -> ControlResponse
        let focus: (ControlRequest) -> ControlResponse
        let screenshot: (String?) -> ControlResponse
        let diagnostics: () -> String
        let remote: (String) -> ControlResponse
    }

    let actions: Actions

    func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.command {
        case "ping":
            return .success("pong")
        case "list-projects":
            return .success(actions.listProjects())
        case "list-status":
            return .success(actions.listStatus())
        case "set-status":
            guard let raw = request.status,
                  let status = SessionStatus(rawValue: raw.lowercased()) else {
                return .failure("invalid status (use idle|running|waiting): \(request.status ?? "")")
            }
            return actions.setStatus(status, request.text, request)
        case "notify":
            guard let title = request.title else { return .failure("notify requires a title") }
            return actions.notify(title, request.body, request)
        case "new-project":
            return actions.newProject(request)
        case "new-session":
            return actions.newSession(request)
        case "rename-project":
            guard let name = request.name else {
                return .failure("rename-project requires a name")
            }
            return actions.renameProject(name, request)
        case "focus":
            return actions.focus(request)
        case "screenshot":
            return actions.screenshot(request.path)
        case "diagnostics":
            return .success(actions.diagnostics())
        case "remote":
            return actions.remote(request.action ?? "status")
        default:
            return .failure("unknown command: \(request.command)")
        }
    }
}
