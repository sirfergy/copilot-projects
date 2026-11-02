import SwiftUI
import CopilotProjectsProtocol

public struct SessionWorkflowView: View {
    public let workflow: RemoteSessionWorkflow
    public let canWrite: Bool
    public let receipts: [RemoteOperationReceipt]
    public let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    @State private var limitText = ""
    @State private var additionalText = ""
    @State private var pending: Set<RemoteSessionActionKind> = []
    @State private var uncertain: [RemoteSessionActionKind: String] = [:]
    @State private var message: String?

    public init(
        workflow: RemoteSessionWorkflow,
        canWrite: Bool,
        receipts: [RemoteOperationReceipt] = [],
        onAction: @escaping @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    ) {
        self.workflow = workflow
        self.canWrite = canWrite
        self.receipts = receipts
        self.onAction = onAction
    }

    public var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if let credits = workflow.totalAiCredits, credits.isFinite, credits >= 0 {
                    Text("Session total: \(credits.formatted(.number.precision(.fractionLength(0...3)))) AI credits")
                } else {
                    Text("Session credit usage unavailable").foregroundStyle(.secondary)
                }
                if let tokens = workflow.contextTokens, let limit = workflow.contextTokenLimit, limit > 0 {
                    Text("Context: \(tokens.formatted()) / \(limit.formatted()) tokens")
                        .font(.caption)
                }
                if !workflow.isFresh() {
                    Label("Runtime information is stale", systemImage: "exclamationmark.triangle")
                } else if let error = workflow.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                if workflow.limitsKnown {
                    Text(workflow.maxAiCredits.map {
                        "Current-window soft limit: \($0.formatted()) AI credits"
                    } ?? "No session soft limit")
                    .font(.caption)
                    Text("Session totals and the current budget window are separate. A model call can exceed a soft limit.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let request = workflow.budgetRequest {
                    Text("Budget decision needed: \(request.usedAiCredits.formatted()) / \(request.maxAiCredits.formatted()) AI credits in this window.")
                        .font(.callout.weight(.semibold))
                    HStack {
                        TextField("Additional AI credits", text: $additionalText)
                            .accessibilityLabel("Additional AI credits")
                        Button("Continue") {
                            submit(RemoteSessionAction(
                                kind: .answerBudget, requestId: request.requestId,
                                additionalAiCredits: Double(additionalText)
                            ))
                        }
                        .disabled(!enabled(.answerBudget) || !(Double(additionalText).map { $0.isFinite && $0 > 0 } ?? false))
                        Button("Stop") {
                            submit(RemoteSessionAction(kind: .answerBudget, requestId: request.requestId))
                        }
                        .disabled(!enabled(.answerBudget))
                        .help("Cancel the model request blocked by this budget")
                    }
                } else if workflow.supports(.setBudget) {
                    HStack {
                        TextField("Soft limit (minimum 30)", text: $limitText)
                            .accessibilityLabel("Session soft limit in AI credits")
                        Button("Set limit") {
                            submit(RemoteSessionAction(kind: .setBudget, maxAiCredits: Double(limitText)))
                        }
                        .disabled(!enabled(.setBudget) || !(Double(limitText).map { $0.isFinite && $0 >= 30 } ?? false))
                        if workflow.maxAiCredits != nil {
                            Button("Remove limit") {
                                submit(RemoteSessionAction(kind: .setBudget))
                            }
                            .disabled(!enabled(.setBudget))
                        }
                    }
                }
                if !workflow.agents.isEmpty {
                    DisclosureGroup("\(workflow.agents.count) active agents") {
                        ForEach(workflow.agents) { agent in
                            VStack(alignment: .leading) {
                                Text(agent.name).font(.caption.weight(.semibold))
                                if let description = agent.description, !description.isEmpty {
                                    Text(description).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !workflow.schedules.isEmpty {
                    DisclosureGroup("\(workflow.schedules.count) schedules") {
                        ForEach(Array(workflow.schedules.enumerated()), id: \.offset) { _, schedule in
                            HStack {
                                Text(schedule).font(.caption)
                                Spacer()
                                if workflow.supports(.send),
                                   workflow.schedules.filter({ $0 == schedule }).count == 1 {
                                    Button("Run Now") {
                                        submit(RemoteSessionAction(
                                            kind: .send,
                                            prompt: "Run scheduled task \(schedule) now",
                                            mode: .immediate
                                        ))
                                    }
                                    .controlSize(.small)
                                    .disabled(!enabled(.send))
                                    Button("Stop", role: .destructive) {
                                        submit(RemoteSessionAction(
                                            kind: .send,
                                            prompt: "Stop schedule \(schedule) using manage_schedule",
                                            mode: .immediate
                                        ))
                                    }
                                    .controlSize(.small)
                                    .disabled(!enabled(.send))
                                }
                            }
                        }
                    }
                }
                if workflow.supports(.abort) {
                    HStack {
                        Button("Stop task", role: .destructive) {
                            submit(RemoteSessionAction(kind: .abort))
                        }
                        .disabled(!enabled(.abort))
                        .help("Request Copilot cancellation without closing this terminal session")
                        if workflow.supports(.send) {
                            Button("Stop & Poke") {
                                submitStopAndPoke()
                            }
                            .disabled(!enabled(.abort) || !enabled(.send))
                            .accessibilityIdentifier("workflow-stop-and-poke")
                        }
                    }
                }
                if let message {
                    Text(message).font(.caption).textSelection(.enabled)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(.top, 8)
        } label: {
            Label(
                workflow.budgetRequest == nil ? "Usage and background work" : "Budget decision needed",
                systemImage: workflow.budgetRequest == nil ? "gauge.with.dots.needle.50percent" : "exclamationmark.circle"
            )
        }
        .font(.callout)
        .onChange(of: workflow.budgetRequest?.requestId) { _, _ in
            uncertain[.answerBudget] = nil
            additionalText = ""
        }
        .onChange(of: receipts) { _, values in
            for (kind, id) in uncertain {
                if let receipt = values.first(where: {
                    $0.operationId == id && $0.kind == kind.rawValue
                        && ($0.state == .applied || $0.state == .rejected)
                }) {
                    uncertain[kind] = nil
                    message = receipt.state == .applied
                        ? "Confirmed by Copilot." : "Copilot did not apply this action."
                }
            }
        }
    }

    private func enabled(_ kind: RemoteSessionActionKind) -> Bool {
        canWrite
            && workflow.supports(kind)
            && (kind != .send || workflow.sendReady)
            && !pending.contains(kind)
            && uncertain[kind] == nil
    }

    private func submit(_ action: RemoteSessionAction) {
        guard action.isValid, enabled(action.kind) else { return }
        pending.insert(action.kind)
        message = "Waiting for Copilot to confirm..."
        Task { @MainActor in
            let result = await onAction(action)
            pending.remove(action.kind)
            if result.state == .indeterminate, action.kind != .abort, let id = result.operationId {
                uncertain[action.kind] = id
            }
            message = result.message ?? (result.state == .applied ? "Accepted by Copilot." : "Action was not applied.")
        }
    }

    private func submitStopAndPoke() {
        let abortAction = RemoteSessionAction(kind: .abort)
        let pokeAction = RemoteSessionAction(kind: .send, prompt: "Keep going!", mode: .enqueue)
        guard abortAction.isValid, pokeAction.isValid, enabled(.abort), enabled(.send) else { return }
        pending.insert(.abort)
        pending.insert(.send)
        message = "Waiting for Copilot to confirm..."
        Task { @MainActor in
            let abortResult = await onAction(abortAction)
            pending.remove(.abort)
            guard abortResult.state == .applied else {
                pending.remove(.send)
                message = abortResult.message ?? "Action was not applied."
                return
            }
            let pokeResult = await onAction(pokeAction)
            pending.remove(.send)
            if pokeResult.state == .indeterminate, let id = pokeResult.operationId {
                uncertain[.send] = id
            }
            message = pokeResult.message ?? (pokeResult.state == .applied ? "Accepted by Copilot." : "Action was not applied.")
        }
    }
}
