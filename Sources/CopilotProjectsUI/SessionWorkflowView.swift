import SwiftUI
import CopilotProjectsProtocol

public struct SessionWorkflowState: Equatable {
    public var limitText = ""
    public var additionalText = ""
    public var pending: Set<RemoteSessionActionKind> = []
    public var uncertain: [RemoteSessionActionKind: String] = [:]
    public var message: String?

    public init() {}

    public mutating func resetBudgetAnswer() {
        uncertain[.answerBudget] = nil
        additionalText = ""
    }

    public mutating func reconcile(receipts: [RemoteOperationReceipt]) {
        for (kind, id) in uncertain {
            if let receipt = receipts.first(where: {
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

public struct SessionWorkflowView: View {
    public let workflow: RemoteSessionWorkflow
    public let canWrite: Bool
    public let receipts: [RemoteOperationReceipt]
    public let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    @State private var state = SessionWorkflowState()

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
            SessionWorkflowContentView(
                workflow: workflow,
                canWrite: canWrite,
                receipts: receipts,
                state: $state,
                onAction: onAction
            )
            .padding(.top, 8)
        } label: {
            Label(
                workflow.budgetRequest == nil ? "Usage and background work" : "Budget decision needed",
                systemImage: workflow.budgetRequest == nil ? "gauge.with.dots.needle.50percent" : "exclamationmark.circle"
            )
        }
        .font(.callout)
        .onChange(of: workflow.budgetRequest?.requestId) { _, _ in
            state.resetBudgetAnswer()
        }
        .onChange(of: receipts) { _, values in
            state.reconcile(receipts: values)
        }
    }
}

public struct SessionWorkflowContentView: View {
    public let workflow: RemoteSessionWorkflow
    public let canWrite: Bool
    public let receipts: [RemoteOperationReceipt]
    @Binding private var state: SessionWorkflowState
    public let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult

    public init(
        workflow: RemoteSessionWorkflow,
        canWrite: Bool,
        receipts: [RemoteOperationReceipt] = [],
        state: Binding<SessionWorkflowState>,
        onAction: @escaping @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    ) {
        self.workflow = workflow
        self.canWrite = canWrite
        self.receipts = receipts
        self._state = state
        self.onAction = onAction
    }

    public var body: some View {
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
            if !isFresh {
                Label("Runtime information is stale", systemImage: "exclamationmark.triangle")
            } else if let error = workflow.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if workflow.limitsKnown {
                Text(workflow.maxAiCredits.map {
                    "Current-window soft limit: \($0.formatted()) AI credits"
                } ?? "No session soft limit")
                .font(.caption)
                Text("Session totals and the current budget window are separate. A model call can exceed a soft limit.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let request = workflow.budgetRequest {
                Text("Budget decision needed: \(request.usedAiCredits.formatted()) / \(request.maxAiCredits.formatted()) AI credits in this window.")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Additional AI credits", text: $state.additionalText)
                        .accessibilityLabel("Additional AI credits")
                    Button("Continue") {
                        submit(RemoteSessionAction(
                            kind: .answerBudget, requestId: request.requestId,
                            additionalAiCredits: Double(state.additionalText)
                        ))
                    }
                    .disabled(!enabled(.answerBudget) || !(Double(state.additionalText).map { $0.isFinite && $0 > 0 } ?? false))
                    Button("Stop") {
                        submit(RemoteSessionAction(kind: .answerBudget, requestId: request.requestId))
                    }
                    .disabled(!enabled(.answerBudget))
                    .help("Cancel the model request blocked by this budget")
                }
            } else if offers(.setBudget) {
                HStack {
                    TextField("Soft limit (minimum 30)", text: $state.limitText)
                        .accessibilityLabel("Session soft limit in AI credits")
                    Button("Set limit") {
                        submit(RemoteSessionAction(kind: .setBudget, maxAiCredits: Double(state.limitText)))
                    }
                    .disabled(!enabled(.setBudget) || !(Double(state.limitText).map { $0.isFinite && $0 >= 30 } ?? false))
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
                            if offers(.send),
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
            if offers(.abort) {
                HStack {
                    Button("Stop task", role: .destructive) {
                        submit(RemoteSessionAction(kind: .abort))
                    }
                    .disabled(!enabled(.abort))
                    .help("Request Copilot cancellation without closing this terminal session")
                    if offers(.send) {
                        Button("Stop & Poke") {
                            submitStopAndPoke()
                        }
                        .disabled(!enabled(.abort) || !enabled(.send))
                        .accessibilityIdentifier("workflow-stop-and-poke")
                    }
                }
            }
            if let message = state.message {
                Text(message).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .font(.callout)
        .onAppear {
            state.reconcile(receipts: receipts)
        }
    }

    /// A workflow the Mac published says whether it is fresh, judged on the
    /// Mac's clock. One without `fresh`, as the Mac's own views pass, is
    /// judged from its observation time on this device's clock.
    private var isFresh: Bool {
        workflow.fresh ?? workflow.isFresh()
    }

    private func offers(_ kind: RemoteSessionActionKind) -> Bool {
        isFresh && workflow.admits(kind)
    }

    private func enabled(_ kind: RemoteSessionActionKind) -> Bool {
        canWrite
            && offers(kind)
            && (kind != .send || workflow.sendReady)
            && !state.pending.contains(kind)
            && state.uncertain[kind] == nil
    }

    private func submit(_ action: RemoteSessionAction) {
        guard action.isValid, enabled(action.kind) else { return }
        state.pending.insert(action.kind)
        state.message = "Waiting for Copilot to confirm..."
        Task { @MainActor in
            let result = await onAction(action)
            state.pending.remove(action.kind)
            if result.state == .indeterminate, action.kind != .abort, let id = result.operationId {
                state.uncertain[action.kind] = id
            }
            state.message = result.message ?? (result.state == .applied ? "Accepted by Copilot." : "Action was not applied.")
        }
    }

    private func submitStopAndPoke() {
        let abortAction = RemoteSessionAction(kind: .abort)
        let pokeAction = RemoteSessionAction(kind: .send, prompt: "Keep going!", mode: .enqueue)
        guard abortAction.isValid, pokeAction.isValid, enabled(.abort), enabled(.send) else { return }
        state.pending.insert(.abort)
        state.pending.insert(.send)
        state.message = "Waiting for Copilot to confirm..."
        Task { @MainActor in
            let abortResult = await onAction(abortAction)
            state.pending.remove(.abort)
            guard abortResult.state == .applied else {
                state.pending.remove(.send)
                state.message = abortResult.message ?? "Action was not applied."
                return
            }
            let pokeResult = await onAction(pokeAction)
            state.pending.remove(.send)
            if pokeResult.state == .indeterminate, let id = pokeResult.operationId {
                state.uncertain[.send] = id
            }
            state.message = pokeResult.message ?? (pokeResult.state == .applied ? "Accepted by Copilot." : "Action was not applied.")
        }
    }
}
