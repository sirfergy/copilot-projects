import Foundation
import SessionDomain

enum SessionSemanticsAdapter {
    static func permissionDecision(
        status: SessionStatus,
        hasPendingQuestions: Bool,
        hasPendingPermissionRequests: Bool?
    ) -> PermissionNotificationDecision {
        switch SessionSemantics.permissionPromptDisposition(
            status: status,
            hasPendingQuestions: hasPendingQuestions,
            hasPendingPermissionRequests: hasPendingPermissionRequests
        ) {
        case .cancel:
            return .cancel
        case .post:
            return .post
        case .suppress:
            return .suppress
        }
    }
}
