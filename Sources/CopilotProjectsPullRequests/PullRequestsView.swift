import AppKit
import SwiftUI
import CopilotProjectsCore
import CopilotProjectsStyle

enum PullRequestsWindow {
    static let id = "pull-requests"
    static let title = "Pull Requests"
    /// The drag strip's height and the traffic lights' inset, as in the workspace window.
    static let titleStripHeight: CGFloat = 38
    static let trafficLightInset: CGFloat = 80
}

/// Drops the title bar separator, as the workspace window does.
private struct TitlebarSeparatorRemover: NSViewRepresentable {
    final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarSeparatorStyle = .none
        }
    }

    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ nsView: MarkerView, context: Context) {}
}

struct PullRequestsView: View {
    @ObservedObject var pullRequests: PullRequestsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chips
    @State private var selection: PullRequestKey?
    @State private var editingOwners = false
    /// Legacy scrollers take width from the lanes; rebuild them when the style changes.
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle
    @FocusState private var lanesFocused: Bool

    static let goalColumnWidth: CGFloat = 240

    var body: some View {
        let goals = pullRequests.goals()
        VStack(spacing: 0) {
            titleStrip
            header(goals)
            Divider()
            content(goals)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer(goals)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(StudioStyle.chrome)
        .background(TitlebarSeparatorRemover())
        .task { await pullRequests.runRefreshLoop() }
        .task { await pullRequests.runWorkspaceLoop() }
    }

    private var titleStrip: some View {
        HStack {
            Text(PullRequestsWindow.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
        }
        .padding(.leading, PullRequestsWindow.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: PullRequestsWindow.titleStripHeight)
        .frame(maxWidth: .infinity)
        .background(StudioStyle.chrome)
    }

    // MARK: Header

    private func header(_ goals: [PullRequestGoal]) -> some View {
        let items = goals.flatMap(\.items)
        let needsYou = items.filter { $0.assessment.needsYou }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(needsYou: needsYou.count, total: items.count))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle(total: items.count, goals: goals.count, nudges: needsYou.filter { $0.assessment.isNudgeOnly }))
                    .font(.caption)
                    .foregroundStyle(StudioStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            refreshStatus
            ownersButton
            Button {
                pullRequests.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .accessibilityLabel("Refresh")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(pullRequests.isRefreshing)
            .help("Refresh (⌘R)")
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private func headline(needsYou: Int, total: Int) -> String {
        if pullRequests.phase != .loaded && total == 0 { return "Open Pull Requests" }
        switch needsYou {
        case 0: return total == 0 ? "No open pull requests" : "Nothing needs you"
        case 1: return "1 needs you"
        default: return "\(needsYou) need you"
        }
    }

    private func subtitle(total: Int, goals: Int, nudges: [PullRequestItem]) -> String {
        if case .failed = pullRequests.phase, total == 0 { return "Nothing loaded yet" }
        if pullRequests.phase != .loaded && total == 0 {
            return "Reading your pull requests from GitHub and matching them to sessions…"
        }
        var parts = ["\(total) open", goals == 1 ? "1 goal" : "\(goals) goals"]
        if !nudges.isEmpty {
            let sessionless = nudges.allSatisfy { $0.assessment.reasons.contains(.noSession) }
            let quiet = nudges.allSatisfy { $0.assessment.reasons.allSatisfy { if case .stale = $0 { true } else { false } } }
            let count = nudges.count
            let need = count == 1 ? "needs" : "need"
            parts.append(sessionless ? "\(count) only \(need) a session"
                         : quiet ? "\(count) only gone quiet"
                         : "\(count) only \(need) a session or a nudge")
        }
        let owners = pullRequests.ownerList
        parts.append(owners.isEmpty ? "every owner" : owners.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if pullRequests.isRefreshing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(refreshingLabel)
            }
            .font(.caption)
            .foregroundStyle(StudioStyle.secondaryText)
            .accessibilityElement(children: .combine)
        } else if let warning = pullRequests.warning {
            Label {
                Text(warning).lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.caption)
            .frame(maxWidth: 280, alignment: .trailing)
            .help(warning)
        } else if let updated = pullRequests.lastUpdated {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("Updated \(updated, format: .relative(presentation: .named))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(StudioStyle.secondaryText)
            }
        }
    }

    private var refreshingLabel: String {
        if pullRequests.pullRequests.isEmpty { return "Loading…" }
        return pullRequests.sessionsMatched ? "Refreshing…" : "Matching sessions…"
    }

    private var ownersButton: some View {
        let owners = pullRequests.ownerList
        return Button {
            editingOwners.toggle()
        } label: {
            Label(Self.ownersLabel(owners), systemImage: "line.3.horizontal.decrease.circle")
                .lineLimit(1)
        }
        .help(owners.isEmpty
              ? "Showing every owner. Choose organizations or users to narrow it."
              : "Showing pull requests in \(owners.joined(separator: ", "))")
        .popover(isPresented: $editingOwners, arrowEdge: .bottom) {
            OwnersEditor(owners: $pullRequests.owners, note: pullRequests.settingsNote) {
                editingOwners = false
                pullRequests.refresh()
            }
        }
    }

    /// Two owners by name, then a count, so a long list doesn't crowd the header.
    static func ownersLabel(_ owners: [String]) -> String {
        switch owners.count {
        case 0: return "Every Owner"
        case 1, 2: return owners.joined(separator: ", ")
        default: return "\(owners[0]), \(owners[1]) +\(owners.count - 2)"
        }
    }

    /// The window's keys, as the session finder shows its own; only those that
    /// can act right now.
    private func footer(_ goals: [PullRequestGoal]) -> some View {
        let lanesShown = pullRequests.phase == .loaded && !goals.isEmpty
        let selected = goals.lazy.flatMap(\.items).first { $0.id == selection }
        let canGoToSession = selected?.session != nil && pullRequests.isConnected
        return HStack(spacing: 14) {
            if lanesShown {
                keyHint("↑↓", "Move")
                if selected != nil {
                    keyHint("↩", canGoToSession ? "Go to Session" : "Open on GitHub")
                    if canGoToSession { keyHint("⌘↩", "Open on GitHub") }
                }
            }
            keyHint("⌘R", "Refresh")
            Spacer(minLength: 12)
            workspaceNote
            if pullRequests.omitted > 0 {
                Text("\(pullRequests.omitted) older pull requests not shown; choose owners to narrow")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.caption)
        .foregroundStyle(StudioStyle.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(StudioStyle.sidebar)
    }

    /// Whether the lanes know the workspace's sessions, said quietly: secondary
    /// ink while Copilot Projects is away, the orange warning only when it must
    /// be updated.
    @ViewBuilder
    private var workspaceNote: some View {
        switch pullRequests.workspace {
        case .disconnected(let lastGood):
            Text(lastGood == nil
                 ? "Copilot Projects isn’t open, so sessions aren’t matched"
                 : "Copilot Projects isn’t open; session states are unknown")
                .lineLimit(1)
                .truncationMode(.tail)
        case .incompatibleHost:
            Label {
                Text("Update Copilot Projects to match sessions")
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .help("This version of Copilot Projects can’t list its sessions, so pull requests aren’t matched to them.")
        case .connecting, .connected:
            EmptyView()
        }
        if let note = pullRequests.settingsNote {
            Label {
                Text(note).lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .help(note)
        }
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
            Text(action)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ goals: [PullRequestGoal]) -> some View {
        switch pullRequests.phase {
        case .failed(let error) where pullRequests.pullRequests.isEmpty:
            ContentUnavailableView {
                Label(error.title, systemImage: error == .cliUnavailable ? "terminal" : "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button("Try Again") { pullRequests.refresh() }
            }
        case .idle, .loading where pullRequests.pullRequests.isEmpty:
            lanes(SkeletonLanes.goals, placeholder: true)
        default:
            if goals.isEmpty {
                ContentUnavailableView {
                    Label("No Open Pull Requests", systemImage: "arrow.triangle.pull")
                } description: {
                    Text(pullRequests.ownerList.isEmpty
                         ? "Pull requests you open appear here, grouped by the session working on them."
                         : "Pull requests you open in \(pullRequests.ownerList.joined(separator: ", ")) appear here.")
                }
            } else {
                lanes(goals, placeholder: false)
            }
        }
    }

    private func lanes(_ goals: [PullRequestGoal], placeholder: Bool) -> some View {
        let order = goals.flatMap { goal in PullRequestStage.allCases.flatMap { goal.items(in: $0) } }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(goals) { goal in
                            GoalLane(
                                goal: goal,
                                selection: selection,
                                chips: chips,
                                animatesMoves: !reduceMotion && !placeholder,
                                workspace: laneWorkspace,
                                projects: pullRequests.projects,
                                defaultProjectId: pullRequests.defaultProjectId,
                                isStarting: pullRequests.startingGoals.contains(goal.id),
                                resumingSessions: pullRequests.resumingSessions,
                                goalChoices: goalChoices(goals),
                                actions: laneActions
                            )
                            Divider()
                        }
                    } header: {
                        stageHeader(goals, placeholder: placeholder)
                    }
                }
            }
            .redacted(reason: placeholder ? .placeholder : [])
            .allowsHitTesting(!placeholder)
            .accessibilityHidden(placeholder)
            .focusable(!placeholder)
            .focused($lanesFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, in: order, proxy: proxy) }
            .onKeyPress(.upArrow) { move(-1, in: order, proxy: proxy) }
            .onKeyPress(.return, phases: .down) { press in
                guard let item = order.first(where: { $0.id == selection }) else { return .ignored }
                if let session = item.session, pullRequests.isConnected, !press.modifiers.contains(.command) {
                    pullRequests.goToSession(session)
                } else {
                    pullRequests.openOnGitHub(item.pr)
                }
                return .handled
            }
            .onKeyPress(.escape) {
                guard selection != nil else { return .ignored }
                selection = nil
                return .handled
            }
            .onAppear {
                guard !placeholder else { return }
                // The most urgent pull request is selected, so Return goes straight to its session.
                if selection == nil { selection = goals.first?.items.first?.id }
                lanesFocused = true
            }
            .id(scrollerStyle)
            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                scrollerStyle = NSScroller.preferredScrollerStyle
            }
        }
    }

    private func move(_ delta: Int, in order: [PullRequestItem], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let current = order.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : order.count)
        let next = order[min(max(current + delta, 0), order.count - 1)]
        selection = next.id
        proxy.scrollTo(next.id)
        if let goal = pullRequests.goals().first(where: { $0.items.contains { $0.id == next.id } }) {
            AccessibilityNotification.Announcement(
                "\(next.pr.shortName), \(next.pr.title), \(goal.name). \(PullRequestChip.statusText(next))"
            ).post()
        }
        return .handled
    }

    private func stageHeader(_ goals: [PullRequestGoal], placeholder: Bool) -> some View {
        HStack(spacing: 0) {
            Text("Goals")
                .padding(.horizontal, 14)
                .frame(width: Self.goalColumnWidth, alignment: .leading)
            ForEach(PullRequestStage.allCases) { stage in
                Divider()
                let count = goals.reduce(0) { $0 + $1.items(in: stage).count }
                HStack(spacing: 6) {
                    Text(stage.title)
                    if count > 0, !placeholder {
                        Text(count, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(StudioStyle.secondaryText)
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(StudioStyle.secondaryText)
        .frame(height: 28)
        .background(StudioStyle.chrome)
        .overlay(alignment: .bottom) { Divider() }
        .unredacted()
        .accessibilityAddTraits(.isHeader)
    }

    /// Goals a pull request can be moved into: session and named goals.
    private func goalChoices(_ goals: [PullRequestGoal]) -> [(id: String, name: String)] {
        goals.filter { $0.kind == .session || $0.kind == .manual }
            .map { ($0.id, $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// What a lane's session button can do with the workspace right now.
    private var laneWorkspace: GoalLane.Workspace {
        switch pullRequests.workspace {
        case .connected: return .connected
        case .disconnected: return pullRequests.canOpenHost ? .openable : .unavailable
        case .connecting, .incompatibleHost: return .unavailable
        }
    }

    private var laneActions: GoalLane.Actions {
        GoalLane.Actions(
            select: { key in
                selection = key
                lanesFocused = true
            },
            openPullRequest: { pullRequests.openOnGitHub($0) },
            copyLink: { pullRequests.copyLink($0) },
            goToSession: { pullRequests.goToSession($0) },
            startSession: { goal, projectId in pullRequests.startSession(for: goal, projectId: projectId) },
            resumeSession: { candidate, projectId in pullRequests.resume(candidate, projectId: projectId) },
            openHost: { pullRequests.openHost() },
            move: { key, goalId in pullRequests.move(key, toGoal: goalId) },
            moveToNewGoal: { item in
                if let name = Self.promptForGoalName(suggested: item.pr.title) {
                    pullRequests.moveToNewGoal(item.pr.key, named: name)
                }
            }
        )
    }

    private static func promptForGoalName(suggested: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "New Goal"
        alert.informativeText = "Name the outcome this pull request works toward. Move other pull requests into it from their menus."
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create Goal")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// One goal: its name and session on the left, its pull requests placed by stage.
private struct GoalLane: View {
    struct Actions {
        let select: (PullRequestKey) -> Void
        let openPullRequest: (PullRequestSnapshot) -> Void
        let copyLink: (PullRequestSnapshot) -> Void
        let goToSession: (PullRequestSession) -> Void
        let startSession: (PullRequestGoal, String) -> Void
        let resumeSession: (ResumableSession, String) -> Void
        let openHost: () -> Void
        let move: (PullRequestKey, String?) -> Void
        let moveToNewGoal: (PullRequestItem) -> Void
    }

    enum Workspace {
        /// Sessions can be shown and started.
        case connected
        /// Copilot Projects isn't answering; the lane offers to open it.
        case openable
        /// Nothing to offer: still connecting, or Copilot Projects is too old.
        case unavailable
    }

    let goal: PullRequestGoal
    let selection: PullRequestKey?
    let chips: Namespace.ID
    let animatesMoves: Bool
    let workspace: Workspace
    let projects: [(id: String, name: String)]
    let defaultProjectId: String?
    let isStarting: Bool
    /// Copilot sessions on their way back; their Resume Session buttons wait.
    let resumingSessions: Set<String>
    let goalChoices: [(id: String, name: String)]
    let actions: Actions

    private var laneSession: PullRequestSession? {
        goal.session ?? goal.items.lazy.compactMap(\.session).first
    }

    /// The ended session to offer, once the workspace has said nothing live drives this goal.
    private var previousSession: ResumableSession? {
        workspace == .connected && laneSession == nil ? goal.resumable : nil
    }

    private static func lastActive(_ session: ResumableSession, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(session.lastActive, now), relativeTo: now)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            summary
                .frame(width: PullRequestsView.goalColumnWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(StudioStyle.sidebar)
            ForEach(PullRequestStage.allCases) { stage in
                Divider()
                VStack(spacing: 6) {
                    ForEach(goal.items(in: stage)) { item in
                        chip(item)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(stage.title), \(goal.name)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(goal.name)
    }

    @ViewBuilder
    private func chip(_ item: PullRequestItem) -> some View {
        let chip = PullRequestChip(
            item: item,
            // A goal named after its pull request doesn't repeat the title.
            showsTitle: PullRequestGrouping.sentenceCase(item.pr.title) != goal.name,
            isSelected: item.id == selection,
            onSelect: { actions.select(item.id) },
            onOpen: { actions.openPullRequest(item.pr) }
        )
        .contextMenu { menu(item) }
        .id(item.id)
        if animatesMoves {
            chip.matchedGeometryEffect(id: item.id, in: chips)
        } else {
            chip.transition(.opacity)
        }
    }

    @ViewBuilder
    private func menu(_ item: PullRequestItem) -> some View {
        Button("Open on GitHub") { actions.openPullRequest(item.pr) }
        if let session = item.session, workspace == .connected {
            Button("Go to Session") { actions.goToSession(session) }
        }
        Button("Copy Link") { actions.copyLink(item.pr) }
        Divider()
        Menu("Move to Goal") {
            ForEach(goalChoices.filter { $0.id != goal.id }, id: \.id) { choice in
                Button(choice.name) { actions.move(item.id, choice.id) }
            }
            if goalChoices.contains(where: { $0.id != goal.id }) { Divider() }
            Button("New Goal…") { actions.moveToNewGoal(item) }
            if item.isManuallyAssigned {
                Button("Use Suggested Goal") { actions.move(item.id, nil) }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(goal.name)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(goal.name)
            context
            counts
            sessionAction
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var context: some View {
        if let session = laneSession {
            HStack(spacing: 6) {
                if PullRequestSessionIndicator.shows(session) {
                    PullRequestSessionIndicator(session: session)
                        .frame(width: 9, height: 9)
                }
                Text("\(session.projectName) · \(session.attentionLabel)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(StudioStyle.secondaryText)
            .accessibilityElement(children: .combine)
        } else if let previous = previousSession {
            Label {
                Text("Previous session · \(Self.lastActive(previous))")
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.caption)
            .foregroundStyle(StudioStyle.secondaryText)
            .help(previous.name)
        } else {
            Label {
                Text(noSessionText)
            } icon: {
                Image(systemName: "terminal")
            }
            .font(.caption)
            .foregroundStyle(StudioStyle.secondaryText)
        }
    }

    /// Only a connected workspace can say a goal has no session.
    private var noSessionText: String {
        guard workspace == .connected else { return "Session unknown" }
        return goal.kind == .manual ? "Your goal · no session" : "No session on this goal"
    }

    private var counts: some View {
        let needsYou = goal.needsYouCount
        var text = goal.items.count == 1 ? "1 pull request" : "\(goal.items.count) pull requests"
        if needsYou > 0 { text += needsYou == 1 ? " · 1 needs you" : " · \(needsYou) need you" }
        return Text(text)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(StudioStyle.secondaryText)
    }

    @ViewBuilder
    private var sessionAction: some View {
        switch workspace {
        case .connected:
            connectedSessionAction
        case .openable:
            Button("Open Copilot Projects", action: actions.openHost)
                .controlSize(.small)
                .help("Open Copilot Projects to match sessions and go to them from here")
        case .unavailable:
            EmptyView()
        }
    }

    @ViewBuilder
    private var connectedSessionAction: some View {
        if let session = laneSession {
            Button("Go to Session") { actions.goToSession(session) }
                .controlSize(.small)
                .help("Show \(PullRequestGrouping.goalName(sessionTitle: session.title)) in the workspace")
        } else if let previous = previousSession, !projects.isEmpty {
            let target = defaultProjectId ?? projects[0].id
            let resuming = resumingSessions.contains(previous.copilotSessionId)
            Menu {
                Section("Resume in") {
                    ForEach(projects, id: \.id) { project in
                        Button(project.name) { actions.resumeSession(previous, project.id) }
                    }
                }
                Divider()
                Section("Start New Session in") {
                    ForEach(projects, id: \.id) { project in
                        Button(project.name) { actions.startSession(goal, project.id) }
                    }
                }
            } label: {
                Text(resuming ? "Resuming…" : "Resume Session")
            } primaryAction: {
                actions.resumeSession(previous, target)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .disabled(resuming || isStarting)
            .help("Resume “\(previous.name)”, last active \(Self.lastActive(previous)), in \(projects.first { $0.id == target }?.name ?? "the current project"); start a new session or choose another project from the menu")
        } else if !projects.isEmpty {
            let target = defaultProjectId ?? projects[0].id
            Menu {
                ForEach(projects, id: \.id) { project in
                    Button(project.name) { actions.startSession(goal, project.id) }
                }
            } label: {
                Text("Start Session")
            } primaryAction: {
                actions.startSession(goal, target)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .disabled(isStarting)
            .help("Start a Copilot session on \(goal.items.count == 1 ? "this pull request" : "these pull requests") in \(projects.first { $0.id == target }?.name ?? "the current project"); choose another project from the menu")
        }
    }
}

/// A session's state beside its project, as the workspace's session list shows
/// it: a small spinner while running, orange while waiting, blue once finished
/// unseen, and nothing otherwise or while its state is unknown.
struct PullRequestSessionIndicator: View {
    let session: PullRequestSession

    static func shows(_ session: PullRequestSession) -> Bool {
        (session.status != nil && session.status != .idle) || session.finishedUnseen
    }

    var body: some View {
        Group {
            switch session.status {
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            case .waiting:
                dot(.orange)
            case .idle where session.finishedUnseen:
                dot(.blue)
            case .idle, nil:
                Color.clear
            }
        }
        .frame(width: 9, height: 9)
        .help(help)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
    }

    private var help: String {
        switch session.status {
        case .running: return "running"
        case .waiting: return "waiting for input"
        case .idle: return session.finishedUnseen ? "finished — ready for you" : "idle"
        case nil: return "status unknown"
        }
    }
}

/// A pull request inside its goal's lane.
struct PullRequestChip: View {
    let item: PullRequestItem
    var showsTitle = true
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var isHovering = false

    static func statusText(_ item: PullRequestItem) -> String {
        item.assessment.reasons.isEmpty
            ? item.assessment.status
            : item.assessment.reasons.map(\.label).joined(separator: ", ")
    }

    private var tint: Color {
        guard let primary = item.assessment.primary else { return StudioStyle.secondaryText }
        if primary == .readyToMerge { return .green }
        return primary.isNudge ? StudioStyle.secondaryText : .orange
    }

    /// Orange for what needs you, green for ready, quiet for nudges. Hover only
    /// strengthens a quiet edge, so it never reads as a weak selection; selection
    /// adds its own ring outside, so the status edge stays visible.
    private var edge: Color {
        guard let primary = item.assessment.primary else {
            if isSelected { return .clear }
            return isHovering ? StudioStyle.secondaryText.opacity(0.8) : .clear
        }
        if primary.isNudge { return StudioStyle.secondaryText.opacity(isHovering ? 0.8 : 0.45) }
        return primary == .readyToMerge ? .green.opacity(0.7) : .orange.opacity(0.85)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Narrow lanes drop the age before they cut into the repository name.
            ViewThatFits(in: .horizontal) {
                identity(showsAge: true)
                identity(showsAge: false)
            }
            if showsTitle {
                Text(item.pr.title)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            reason
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? StudioStyle.selection : StudioStyle.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(edge, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? StudioStyle.selectionEdge : .clear, lineWidth: 1)
                .padding(-2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(count: 2, perform: onOpen)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.pr.shortName), \(item.pr.title)")
        .accessibilityValue(Self.statusText(item))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: "Open on GitHub", onOpen)
    }

    /// `repo#number`, then how long ago it changed when that fits too.
    @ViewBuilder
    private func identity(showsAge: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(spacing: 0) {
                Text(item.pr.repositoryName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: showsAge, vertical: false)
                Text(verbatim: "#\(item.pr.key.number)")
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(StudioStyle.secondaryText)
            if showsAge {
                Spacer(minLength: 4)
                Text(item.pr.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(StudioStyle.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    /// The most urgent reason, shortened before it is ever cut off; "+N" counts the rest.
    @ViewBuilder
    private var reason: some View {
        if let primary = item.assessment.primary {
            ViewThatFits(in: .horizontal) {
                reasonLine(primary, primary.label, showsMore: true)
                reasonLine(primary, primary.shortLabel, showsMore: true)
                reasonLine(primary, primary.shortLabel, showsMore: false)
            }
            .font(.caption)
        } else {
            Text(item.assessment.status)
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reasonLine(_ primary: PullRequestAttention, _ text: String, showsMore: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: primary.symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(primary.isNudge ? StudioStyle.secondaryText : Color.primary)
                .lineLimit(1)
                .fixedSize()
            let more = item.assessment.reasons.count - 1
            if showsMore, more > 0 {
                Text("+\(more)")
                    .monospacedDigit()
                    .foregroundStyle(StudioStyle.secondaryText)
                    .fixedSize()
            }
        }
    }

    private var help: String {
        var lines = ["\(item.pr.repository)#\(item.pr.key.number): \(item.pr.title)"]
        lines += item.assessment.reasons.map { "• \($0.label)" }
        if item.assessment.reasons.isEmpty { lines.append(item.assessment.status) }
        if let failing = item.pr.failingRequiredChecks, !failing.isEmpty {
            lines.append("Failing: " + failing.prefix(5).joined(separator: ", "))
        }
        lines.append("Double-click to open on GitHub")
        return lines.joined(separator: "\n")
    }
}

private struct OwnersEditor: View {
    @Binding var owners: String
    /// Why these owners stay in this app rather than Copilot Projects' settings.
    let note: String?
    let onDone: () -> Void
    @State private var draft: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Owners")
                .font(.headline)
            Text("Show only your pull requests in these organizations or users. Leave empty to include every owner.")
                .font(.callout)
                .foregroundStyle(StudioStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            OwnersTokenField(owners: $draft, onSubmit: commit)
                .frame(minHeight: 24)
            Text("Separate owners with commas or spaces; Return applies.")
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
            if let note {
                Label {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { commit(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { draft = PullRequestsModel.ownerList(owners) }
    }

    private func commit(_ tokens: [String]) {
        owners = PullRequestsModel.ownerList(tokens.joined(separator: ",")).joined(separator: ", ")
        onDone()
    }
}

/// A native token field: each organization or user is its own token, removable
/// on its own, so several owners read as a list rather than one string.
struct OwnersTokenField: NSViewRepresentable {
    @Binding var owners: [String]
    let onSubmit: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owners: $owners, onSubmit: onSubmit) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines)
        field.placeholderString = "github, my-org"
        field.objectValue = owners
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Owners")
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.owners = $owners
        context.coordinator.onSubmit = onSubmit
        // Leave the field alone while someone is typing in it.
        guard field.currentEditor() == nil, Coordinator.tokens(in: field) != owners else { return }
        field.objectValue = owners
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var owners: Binding<[String]>
        var onSubmit: ([String]) -> Void

        init(owners: Binding<[String]>, onSubmit: @escaping ([String]) -> Void) {
            self.owners = owners
            self.onSubmit = onSubmit
        }

        /// Every token, plus anything typed but not yet turned into one.
        static func tokens(in field: NSTokenField) -> [String] {
            PullRequestsModel.ownerList(field.stringValue)
        }

        /// Drops a leading @ and anything that can't be a GitHub owner.
        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            PullRequestsModel.ownerList(tokens.compactMap { $0 as? String }.joined(separator: ","))
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            owners.wrappedValue = Self.tokens(in: field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            owners.wrappedValue = Self.tokens(in: field)
        }

        /// The field spends Return on tokenizing, so the default button never
        /// sees it; apply from here instead, pending text included.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let field = control as? NSTokenField else { return false }
            let tokens = Self.tokens(in: field)
            owners.wrappedValue = tokens
            onSubmit(tokens)
            return true
        }
    }
}

/// Placeholder lanes shown, redacted, while the first fetch runs.
private enum SkeletonLanes {
    static let goals: [PullRequestGoal] = (0..<3).map { lane in
        let items = (0..<(lane == 0 ? 3 : 2)).map { index -> PullRequestItem in
            let key = PullRequestKey(owner: "placeholder", repo: "lane\(lane)", number: index + 1)
            let pr = PullRequestSnapshot(
                key: key, nodeId: key.description, repository: "placeholder/repository",
                title: "Placeholder pull request title", url: URL(string: "https://github.com")!,
                author: "", isDraft: false, createdAt: .distantPast, updatedAt: Date(),
                headRefName: "", reviewDecision: .reviewRequired, checks: .success,
                unresolvedThreads: 0, unresolvedCopilotThreads: 0, inMergeQueue: false, autoMergeEnabled: false
            )
            let stage = PullRequestStage.allCases[(lane + index * 2) % PullRequestStage.allCases.count]
            return PullRequestItem(
                pr: pr, assessment: PullRequestAssessment(stage: stage, reasons: [], status: "Awaiting review"),
                session: nil, isManuallyAssigned: false
            )
        }
        return PullRequestGoal(
            id: "placeholder-\(lane)", kind: .single, name: "Placeholder goal name", session: nil, items: items
        )
    }
}
