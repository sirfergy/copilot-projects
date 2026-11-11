import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CopilotProjectsCore
import CopilotProjectsProtocol

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var input: WorkspaceInputController
    @Binding var showsProjects: Bool

    // Keep controls below the drag strip; AppEntry uses the same 38pt boundary.
    private let titleStripHeight: CGFloat = 38

    var body: some View {
        VStack(spacing: 0) {
            topStrip
            ProjectSplitView(showsProjects: showsProjects, onProjectsHidden: focusVisibleWorkspace) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Projects").font(.headline)
                        Spacer()
                        Text(model.projects.count, format: .number)
                            .foregroundStyle(StudioStyle.secondaryText)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 56)
                    Divider()
                    SidebarView(model: model)
                }
                .background(StudioStyle.sidebar)
                .disabled(!showsProjects)
                .allowsHitTesting(showsProjects)
                .accessibilityHidden(!showsProjects)
            } content: {
                HSplitView {
                    SessionBrowser(model: model, showsProjects: $showsProjects)
                        .frame(minWidth: 200, idealWidth: 224, maxWidth: 280)
                        .background(SplitViewAutosaver(name: "copilot-projects.sessions"))
                    VStack(spacing: 0) {
                        WorkspaceHeading(model: model)
                        Divider()
                        DetailView(model: model, onPreview: input.presentImage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // Its split view measures this pane at its ideal width. Left to the content, that
                    // was the message box's one-line text, so typing in the full-width transcript
                    // re-measured every message at the typed text's width.
                    .frame(minWidth: 420, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(StudioStyle.chrome)
        .background(WindowConfigurator())
        .sheet(item: sessionFinderBinding) { finder in
            SessionFinderView(finder: finder, model: model, onDismiss: input.dismissSessionFinder)
        }
        .sheet(item: $input.imagePreview) { item in
            TranscriptImagePreview(item: item) { input.imagePreview = nil }
        }
        .sheet(isPresented: $input.showsReleaseNotes) {
            ReleaseNotesView { input.showsReleaseNotes = false }
        }
        .onChange(of: previewSessionId) { _, sessionId in
            if let preview = input.imagePreview, preview.id.sessionId != sessionId {
                input.imagePreview = nil
            }
        }
        .onDisappear {
            input.imagePreview = nil
            input.dismissSessionFinder()
            input.showsReleaseNotes = false
        }
    }

    private var sessionFinderBinding: Binding<SessionFinderModel?> {
        Binding(
            get: { input.sessionFinder },
            set: { if $0 == nil { input.dismissSessionFinder() } }
        )
    }

    private var previewSessionId: String? {
        guard let sessionId = model.globalSelectedSessionId,
              model.isTranscriptDrawerOpen(sessionId: sessionId) else { return nil }
        return sessionId
    }

    private func focusVisibleWorkspace(in window: NSWindow) {
        if let terminal = model.activeController?.terminalView,
           !terminal.isHidden, terminal.window === window {
            model.focusActiveTerminal()
        } else if !(window.firstResponder is NSTextView) {
            window.makeFirstResponder(nil)
        }
    }

    private var topStrip: some View {
        HStack(spacing: 10) {
            SessionHistoryButtons(model: model)
            Text("Copilot Projects")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
            FleetStatusBar(model: model)
        }
        .padding(.leading, 80)
        .padding(.trailing, 12)
        .frame(height: titleStripHeight)
        .frame(maxWidth: .infinity)
        .background(StudioStyle.chrome)
    }

}

private struct SessionHistoryButtons: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            Button {
                model.navigateSessionBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!model.canNavigateSessionBack)
            .help(model.previousHistorySessionTitle.map { "Back to \($0) (⌘[)" } ?? "Back (⌘[)")
            .accessibilityLabel("Back")
            .accessibilityIdentifier("session-history-back")
            .contextMenu {
                ForEach(model.backHistoryMenuItems) { item in
                    Button(item.menuTitle) {
                        model.navigateToSessionHistory(index: item.index)
                    }
                }
            }

            Button {
                model.navigateSessionForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!model.canNavigateSessionForward)
            .help(model.nextHistorySessionTitle.map { "Forward to \($0) (⌘])" } ?? "Forward (⌘])")
            .accessibilityLabel("Forward")
            .accessibilityIdentifier("session-history-forward")
            .contextMenu {
                ForEach(model.forwardHistoryMenuItems) { item in
                    Button(item.menuTitle) {
                        model.navigateToSessionHistory(index: item.index)
                    }
                }
            }
        }
        .background(FleetStatusBarHitArea())
    }
}

private struct WorkspaceHeading: View {
    @ObservedObject var model: AppModel

    private var session: Session? {
        guard let project = model.selectedProject else { return nil }
        return project.sessions.first { $0.id == project.selectedSessionId }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(session?.title ?? model.selectedProject?.name ?? "Workspace")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(session?.title ?? model.selectedProject?.name ?? "Workspace")
            if let session, let hostName = model.resolvedRemoteHost(for: session)?.displayName {
                HostBadge(name: hostName)
            }
            if let session, let memoryBytes = session.memoryUsageBytes, memoryBytes > 0 {
                SessionMemoryBadge(bytes: memoryBytes)
            }
            Spacer(minLength: 0)
            if let sessionId = model.globalSelectedSessionId,
               let transcript = model.activeTranscriptController {
                let operation = model.sessionOperationProjection(sessionId: sessionId)
                TranscriptButton(
                    controller: transcript,
                    isOpen: model.isTranscriptDrawerOpen(sessionId: sessionId),
                    workflow: model.sessionWorkflow(sessionId: sessionId),
                    workflowProvider: { model.sessionWorkflow(sessionId: sessionId) },
                    modelInfo: model.sessionModelInfo(sessionId: sessionId),
                    availableModels: model.sessionAvailableModels(sessionId: sessionId),
                    operation: operation,
                    receipts: operation.receipts ?? [],
                    conversationEpoch: operation.conversationEpoch,
                    hasPendingQuestions: !model.sessionPendingUserInputs(sessionId: sessionId).isEmpty
                        || !model.sessionPendingElicitations(sessionId: sessionId).isEmpty,
                    trackerWarning: session?.trackerWarning,
                    onOpen: { model.openTranscriptDrawer(sessionId: sessionId) },
                    onClose: {
                        model.closeTranscriptDrawer(sessionId: sessionId)
                        model.focusActiveTerminal()
                    },
                    onAction: { action in
                        await model.performLocalSessionAction(
                            sessionId: sessionId,
                            action: action,
                            expectedConversationEpoch: operation.conversationEpoch
                        )
                    },
                    onSwitchModel: { selection in
                        await model.performLocalModelSwitch(
                            sessionId: sessionId,
                            selection: selection,
                            expectedConversationEpoch: operation.conversationEpoch
                        )
                    }
                )
                .id(sessionId)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(StudioStyle.raised)
    }
}

/// Removes the title-bar/content separator (a thin line that can pick up the
/// accent color under the strip) and keeps chrome minimal. Retries until the
/// window is attached (it's nil at first).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        func apply(_ attempt: Int) {
            if let window = view.window {
                window.titlebarSeparatorStyle = .none
            } else if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { apply(attempt + 1) }
            }
        }
        DispatchQueue.main.async { apply(0) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Roll-up of what every agent is doing, drawn as a trailing title-bar accessory:
/// the running count (green), background-work sessions (purple), queued schedules
/// (indigo), then the waiting (orange), failed (red), and ready (blue) counts;
/// "all idle" when nothing is active. Clicking any active count jumps to the next
/// session in that state across all projects.
struct FleetStatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let running = model.totalRunning
        let background = model.totalBackgroundWork
        let scheduled = model.totalScheduled
        let waiting = model.totalWaiting
        let failed = model.totalFailed
        let ready = model.totalReady
        HStack(spacing: 10) {
            if running > 0 {
                pill(
                    .running,
                    help: "Jump to next running session",
                    accessibilityLabel: "\(running) running"
                ) {
                    fleetCount(running, "waveform", .green)
                }
            }
            if background > 0 {
                pill(
                    .background,
                    help: "Jump to next background-work session",
                    accessibilityLabel: "\(background) background"
                ) {
                    fleetCount(background, "sparkles", .purple)
                }
            }
            if scheduled > 0 {
                pill(
                    .scheduled,
                    help: "Jump to next scheduled session",
                    accessibilityLabel: "\(scheduled) scheduled"
                ) {
                    fleetCount(scheduled, "clock.arrow.circlepath", .indigo)
                }
            }
            if waiting > 0 {
                pill(
                    .waiting,
                    help: "Jump to next session waiting for input (⇧⌘A)",
                    accessibilityLabel: "\(waiting) waiting"
                ) {
                    fleetCount(waiting, "questionmark.bubble.fill", .orange)
                }
            }
            if failed > 0 {
                pill(
                    .failed,
                    help: "Jump to next session with a failed request (⇧⌘A)",
                    accessibilityLabel: "\(failed) failed"
                ) {
                    fleetCount(failed, "exclamationmark.triangle.fill", .red)
                }
            }
            if ready > 0 {
                pill(
                    .ready,
                    help: "Jump to next finished session (⇧⌘A)",
                    accessibilityLabel: "\(ready) ready"
                ) {
                    fleetCount(ready, "checkmark.circle.fill", .blue)
                }
            }
            if running == 0, background == 0, scheduled == 0, waiting == 0, failed == 0, ready == 0 {
                Text("all idle")
                    .foregroundStyle(StudioStyle.secondaryText)
                    .allowsHitTesting(false)
            }
            if !model.hostHealth.isEmpty {
                HostHealthPill(model: model)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .background(
            Group {
                if running > 0 || background > 0 || scheduled > 0 || waiting > 0 || failed > 0 || ready > 0 || !model.hostHealth.isEmpty {
                    FleetStatusBarHitArea()
                }
            }
        )
    }

    private func fleetCount(_ count: Int, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(count, format: .number)
        }
        .foregroundStyle(color)
    }

    private func pill<Label: View>(
        _ kind: FleetActivityKind,
        help: String,
        accessibilityLabel: String,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            model.selectNextSession(matching: kind)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("fleet-status-\(kind.rawValue)")
    }
}

struct HostHealthPill: View {
    @ObservedObject var model: AppModel
    @State private var showsPopover = false

    static func overallLevel(for hosts: [RemoteHostHealth]) -> RemoteHostHealthLevel {
        hosts.map(\.level).max() ?? .healthy
    }

    static func color(for level: RemoteHostHealthLevel) -> Color {
        switch level {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    static let maximumSummaryLabelCharacters = 36

    static func summaryLabel(for hosts: [RemoteHostHealth]) -> String {
        guard !hosts.isEmpty else { return "Hosts" }
        let raw: String
        let problemHosts = hosts.filter { $0.level > .healthy }
        if let worst = problemHosts.max(by: { $0.level < $1.level }) {
            let reason = worst.statusSummary ?? worst.level.rawValue.capitalized
            if problemHosts.count > 1 {
                raw = "\(problemHosts.count) hosts: \(worst.displayName): \(reason)"
            } else {
                raw = hosts.count > 1 ? "\(worst.displayName): \(reason)" : reason
            }
        } else {
            let primary = hosts.first(where: \.isLocal) ?? hosts[0]
            if let cpu = primary.cpuUsagePercent, let memory = primary.memoryUsagePercent {
                raw = hosts.count > 1
                    ? "\(hosts.count) hosts · CPU \(cpu)%"
                    : "CPU \(cpu)% · Mem \(memory)%"
            } else {
                raw = hosts.count > 1 ? "\(hosts.count) hosts" : "Healthy"
            }
        }
        guard raw.count > maximumSummaryLabelCharacters else { return raw }
        return String(raw.prefix(maximumSummaryLabelCharacters - 1)) + "…"
    }

    static func formattedDiskFree(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    static func metricsDescription(for host: RemoteHostHealth) -> String {
        guard host.reachable else { return "Unreachable" }
        var parts: [String] = []
        if let cpu = host.cpuUsagePercent {
            parts.append("CPU \(cpu)%")
        }
        if let memory = host.memoryUsagePercent {
            parts.append("Mem \(memory)%")
        }
        if let available = host.diskAvailableBytes {
            if let total = host.diskTotalBytes, total > 0 {
                parts.append("\(formattedDiskFree(available)) / \(formattedDiskFree(total)) free")
            } else {
                parts.append("\(formattedDiskFree(available)) free")
            }
        }
        if !host.isLocal, let latency = host.latencyMilliseconds {
            parts.append("\(latency) ms")
        }
        return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
    }

    var body: some View {
        let hosts = model.hostHealth
        let level = Self.overallLevel(for: hosts)
        let label = Self.summaryLabel(for: hosts)
        let accessibilityLabel = "Host health: \(level.rawValue.capitalized). \(label)"

        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Self.color(for: level))
                    .frame(width: 7, height: 7)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading)
                    .foregroundStyle(level == .healthy ? StudioStyle.secondaryText : Self.color(for: level))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(StudioStyle.raised)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("fleet-status-host-health")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            HostHealthPopover(model: model)
        }
    }
}

private struct HostHealthPopover: View {
    @ObservedObject var model: AppModel

    private var hostRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.hostHealth) { host in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(HostHealthPill.color(for: host.level))
                            .frame(width: 7, height: 7)
                        Text(host.displayName)
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 8)
                        if let summary = host.statusSummary {
                            Text(summary)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(HostHealthPill.color(for: host.level))
                        } else {
                            Text("Healthy")
                                .font(.caption2)
                                .foregroundStyle(StudioStyle.secondaryText)
                        }
                    }
                    Text(HostHealthPill.metricsDescription(for: host))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(StudioStyle.secondaryText)
                        .padding(.leading, 13)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Host Health")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 16)
                Button("Refresh") {
                    model.refreshHostHealth()
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .accessibilityIdentifier("host-health-refresh")
            }

            Divider()

            ViewThatFits(in: .vertical) {
                hostRows
                ScrollView {
                    hostRows
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(12)
        .frame(minWidth: 260)
    }
}

/// Marks the interactive region of `FleetStatusBar` in the window's view tree so
/// double-clicking a status pill never triggers the title-bar zoom gesture.
final class FleetStatusBarMarkerView: NSView {
    static func contains(_ locationInWindow: NSPoint, in view: NSView?) -> Bool {
        guard let view, !view.isHidden else { return false }
        if let marker = view as? FleetStatusBarMarkerView {
            let local = marker.convert(locationInWindow, from: nil)
            if marker.bounds.contains(local) { return true }
        }
        return view.subviews.contains { contains(locationInWindow, in: $0) }
    }
}

private struct FleetStatusBarHitArea: NSViewRepresentable {
    func makeNSView(context: Context) -> FleetStatusBarMarkerView {
        FleetStatusBarMarkerView()
    }

    func updateNSView(_ nsView: FleetStatusBarMarkerView, context: Context) {}
}

/// Gives the HSplitView's underlying NSSplitView an autosave name so it persists
/// its divider position natively (SwiftUI's HSplitView doesn't expose this, and
/// loses the width on relaunch otherwise). Walks up from a background view to
/// find the NSSplitView.
struct SplitViewAutosaver: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            var ancestor = view?.superview
            while let current = ancestor, !(current is NSSplitView) { ancestor = current.superview }
            if let split = ancestor as? NSSplitView, split.autosaveName != name {
                // Keep Sessions at its chosen width when Projects collapses; its controller owns sizing.
                if let controller = split.delegate as? NSSplitViewController {
                    controller.splitViewItems.first?.holdingPriority = .init(251)
                }
                split.autosaveName = name
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargetProjectId: String?

    var body: some View {
        let hosts = model.availableHosts
        List(selection: Binding(
            get: { model.selectedProjectId },
            set: { model.selectProject($0) }
        )) {
            ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                ProjectRow(
                    project: project,
                    hostDisplayName: project.defaultHostId.flatMap { raw in
                        guard !raw.isEmpty else { return nil }
                        return SSHHostCatalog.resolve(hostId: raw, in: hosts)?.displayName ?? raw
                    },
                    number: index < 9 ? index + 1 : nil,
                    showNumber: model.numberHint == .projects,
                    isDropTarget: dropTargetProjectId == project.id
                )
                    .equatable()
                    .tag(project.id)
                    .onDrop(of: [.text], delegate: ProjectDropDelegate(
                        projectId: project.id,
                        dropTargetProjectId: $dropTargetProjectId,
                        model: model))
                    .contextMenu {
                        Button("New Copilot Session") { model.addCopilotSessionInteractive(toProjectId: project.id) }
                        Button("Start with Prompt…") {
                            model.addCopilotSessionInteractive(toProjectId: project.id, withPrompt: true)
                        }
                        Button("New Terminal") { model.addSession(toProjectId: project.id) }
                        if model.availableHosts.count > 1 || project.defaultHostId != nil {
                            Divider()
                            Menu("Default Host") {
                                let currentHostId = model.effectiveHostId(forProjectId: project.id)
                                ForEach(model.availableHosts) { host in
                                    Button {
                                        model.setProjectDefaultHost(project.id, hostId: host.id)
                                    } label: {
                                        if currentHostId.caseInsensitiveCompare(host.id) == .orderedSame {
                                            Label(host.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(host.displayName)
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Rename…") { model.renameProjectInteractive(project.id) }
                        Divider()
                        Button("End Project", role: .destructive) {
                            model.requestCloseProject(project.id)
                        }
                    }
            }
            .onMove { model.moveProjects(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(StudioStyle.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.addProjectInteractive()
                } label: {
                    Label("New Project", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .hoverHighlight()

                Text("v\(CLIMain.versionNumber)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(StudioStyle.secondaryText)
            }
            .padding(12)
            .background(StudioStyle.sidebar)
        }
    }
}

struct ProjectRow: View, Equatable {
    let project: Project
    var hostDisplayName: String? = nil
    var number: Int? = nil
    var showNumber: Bool = false
    var isDropTarget: Bool = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.number == rhs.number
            && lhs.showNumber == rhs.showNumber
            && lhs.isDropTarget == rhs.isDropTarget
            && lhs.hostDisplayName == rhs.hostDisplayName
            && lhs.project.id == rhs.project.id
            && lhs.project.name == rhs.project.name
            && lhs.project.defaultHostId == rhs.project.defaultHostId
            && lhs.project.sessions.count == rhs.project.sessions.count
            && lhs.project.hasUnread == rhs.project.hasUnread
            && lhs.project.sessions.filter(\.isUnread).count == rhs.project.sessions.filter(\.isUnread).count
            && lhs.project.runningCount == rhs.project.runningCount
            && lhs.project.backgroundWorkCount == rhs.project.backgroundWorkCount
            && lhs.project.scheduledCount == rhs.project.scheduledCount
            && lhs.project.waitingCount == rhs.project.waitingCount
            && lhs.project.failedCount == rhs.project.failedCount
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .help(project.name)
                if let hostLabel = hostDisplayName ?? project.defaultHostId, !hostLabel.isEmpty {
                    HostBadge(name: hostLabel)
                }
                Text("\(project.sessions.count) session\(project.sessions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .lineLimit(1)
                statusLine
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if showNumber, let number {
                NumberBadge(number: number)
            } else if project.hasUnread {
                let unreadCount = project.sessions.filter(\.isUnread).count
                HStack(spacing: 3) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(unreadCount, format: .number)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.42), lineWidth: 0.5)
                )
                .help("\(unreadCount) unread session\(unreadCount == 1 ? "" : "s")")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(unreadCount) unread session\(unreadCount == 1 ? "" : "s")")
            }
        }
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: isDropTarget ? 2 : 0)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(isDropTarget ? 0.15 : 0))
                )
                .padding(.horizontal, -5)
                .padding(.vertical, -2)
        )
    }

    /// Active counts in the compact fallback's priority order; the tooltip and
    /// accessibility label join all of them.
    static func activityDescriptions(for project: Project) -> [String] {
        [
            (project.waitingCount, "waiting for input"), (project.failedCount, "failed"),
            (project.runningCount, "running"), (project.backgroundWorkCount, "background"),
            (project.scheduledCount, "scheduled"),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
    }

    // Keep one compact status line so changing activity does not move projects.
    @ViewBuilder private var statusLine: some View {
        let running = project.runningCount
        let background = project.backgroundWorkCount
        let scheduled = project.scheduledCount
        let waiting = project.waitingCount
        let failed = project.failedCount
        let descriptions = Self.activityDescriptions(for: project)
        if !descriptions.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    if running > 0 { activityCount(running, "waveform", .green) }
                    if background > 0 { activityCount(background, "sparkles", .purple) }
                    if scheduled > 0 { activityCount(scheduled, "clock.arrow.circlepath", .indigo) }
                    if waiting > 0 { activityCount(waiting, "questionmark.bubble.fill", .orange) }
                    // Same symbol as the session row's failure indicator.
                    if failed > 0 { activityCount(failed, "exclamationmark.triangle.fill", .red) }
                }
                .fixedSize()
                Text(descriptions[0]).lineLimit(1)
            }
            .help(descriptions.joined(separator: ", "))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(descriptions.joined(separator: ", "))
        } else {
            Text("idle")
        }
    }

    private func activityCount(_ count: Int, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(count, format: .number).monospacedDigit()
        }
    }
}

/// The 18×18 status badge at the left of a session row.
/// SessionRow suppresses its separate unread badge when completion already shows the blue checkmark.
struct SessionStateIndicator: View, Equatable {
    let session: Session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session.displayStatus == rhs.session.displayStatus
            && lhs.session.failedRequest == rhs.session.failedRequest
            && lhs.session.finishedUnseen == rhs.session.finishedUnseen
            && lhs.session.hasBackgroundWork == rhs.session.hasBackgroundWork
            && lhs.session.isUnread == rhs.session.isUnread
            && lhs.session.markedUnread == rhs.session.markedUnread
            && lhs.session.parked?.state == rhs.session.parked?.state
    }

    static func symbolName(for session: Session) -> String {
        if let parked = session.parked {
            return parked.state == .failed ? "exclamationmark.triangle.fill" : "moon.zzz.fill"
        }
        switch session.displayStatus {
        case .running:
            return "waveform"
        case .waiting:
            return "questionmark.bubble.fill"
        case .idle:
            if session.failedRequest != nil { return "exclamationmark.triangle.fill" }
            if session.finishedUnseen { return "checkmark.circle.fill" }
            if session.hasBackgroundWork { return "sparkles" }
            if session.isUnread {
                return session.markedUnread ? "envelope.badge.fill" : "bell.badge.fill"
            }
            return "terminal.fill"
        }
    }

    var body: some View {
        let isBackgroundIdle = session.displayStatus == .idle
            && session.failedRequest == nil
            && !session.finishedUnseen
            && session.hasBackgroundWork
        ZStack {
            Circle()
                .fill(badgeTint.opacity(isIdle ? 0.08 : 0.16))
            Circle()
                .strokeBorder(badgeTint.opacity(isIdle ? 0.16 : 0.38), lineWidth: 0.75)
            Image(systemName: Self.symbolName(for: session))
                .font(.system(size: isIdle ? 8.5 : 10, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isIdle ? StudioStyle.secondaryText.opacity(0.8) : badgeTint)
                .symbolEffect(.variableColor.iterative, isActive: session.displayStatus == .running && !reduceMotion)
                .symbolEffect(.pulse, isActive: isBackgroundIdle && !reduceMotion)
        }
        .frame(width: 18, height: 18)
        .help(help)
    }

    private var isIdle: Bool {
        session.displayStatus == .idle
            && session.failedRequest == nil
            && !session.finishedUnseen
            && !session.hasBackgroundWork
            && !session.isUnread
    }

    private var badgeTint: Color {
        switch session.displayStatus {
        case .running: return .green
        case .waiting: return .orange
        case .idle:
            if session.failedRequest != nil { return .red }
            if session.finishedUnseen { return .blue }
            if session.hasBackgroundWork { return .purple }
            if session.isUnread { return .accentColor }
            return .primary
        }
    }

    private var help: String {
        if let parked = session.parked { return parked.label.lowercased() }
        switch session.displayStatus {
        case .running: return "running"
        case .waiting: return "waiting for input"
        case .idle:
            if let failure = session.failedRequest {
                return "request failed — \(failure.message)"
            }
            if session.finishedUnseen { return "finished — ready for you" }
            if session.hasBackgroundWork { return "background work active" }
            if session.isUnread {
                return session.markedUnread ? "marked unread" : "unread — ready for you"
            }
            return "idle"
        }
    }
}

/// Shown on a tab and its project's sidebar row while background work is active.
struct BackgroundWorkBadge: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool { true }

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 8.5, weight: .semibold))
            .symbolEffect(.pulse, isActive: !reduceMotion)
            .foregroundStyle(.purple)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.purple.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.purple.opacity(0.38), lineWidth: 0.5)
            )
            .help("background work active")
            .accessibilityIdentifier("session-background-work-badge")
    }
}

struct ScheduleBadge: View, Equatable {
    let schedules: [TrackedSchedule]

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 8.5, weight: .semibold))
            if schedules.count > 1 {
                Text("\(schedules.count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.indigo)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.indigo.opacity(0.16))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.38), lineWidth: 0.5)
        )
        .help(schedules.map(\.helpText).joined(separator: "\n\n"))
        .accessibilityIdentifier("session-schedule-badge")
    }
}

struct UnreadBadge: View, Equatable {
    var isMarkedUnread: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isMarkedUnread ? "envelope.badge.fill" : "bell.badge.fill")
                .font(.system(size: 8.5, weight: .semibold))
            Text("unread")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Color.accentColor)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 0.5)
        )
        .help(isMarkedUnread ? "marked unread" : "unread activity")
        .accessibilityHidden(true)
        .accessibilityIdentifier("session-unread-badge")
    }
}

/// Keycap-style number shown on projects (⌘) / tabs (⌃) while the modifier is held.
struct NumberBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }
}

// MARK: - Terminal workspace

struct DetailView: View {
    @ObservedObject var model: AppModel
    let onPreview: (TranscriptImagePreviewItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TranscriptDrawer.fullWidthTranscriptKey) private var isFullWidth = false

    private var parked: ParkedSession? {
        model.selectedProject?.sessions.first { $0.id == model.globalSelectedSessionId }?.parked
    }

    var body: some View {
        // One persistent AppKit container hosts every session's terminal across all
        // projects (see TerminalsContainerView). It's created once and never
        // unmounted, so switching projects or tabs is just a z-order change — SwiftUI
        // never remounts the terminal NSViews, which is what caused the
        // repaint-on-reveal flashes the old opacity/zIndex ZStack couldn't fully fix.
        // Empty / no-project states are drawn by the container's own cover view.
        // activeSessionId + hostedIds are passed so SwiftUI re-runs updateNSView when
        // the selection or the set of sessions changes.
        ZStack(alignment: .trailing) {
            TerminalsContainer(
                model: model,
                activeSessionId: model.globalSelectedSessionId,
                hostedIds: model.hostedTerminals.map(\.id),
                showsTerminal: parked == nil
                    && !model.isActiveTerminalCoveredByTranscriptDrawer(isFullWidth: isFullWidth)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let sessionId = model.globalSelectedSessionId, let parked {
                ParkedSessionPlaceholder(model: model, sessionId: sessionId, state: parked.state)
            }

            if let sessionId = model.globalSelectedSessionId,
               let transcript = model.activeTranscriptController {
                let isOpen = model.isTranscriptDrawerOpen(sessionId: sessionId)
                let operation = model.sessionOperationProjection(sessionId: sessionId)
                let composer = model.sessionPromptComposer(sessionId: sessionId)
                TranscriptOverlay(
                    controller: transcript,
                    imageCapture: { model.terminalView(for: sessionId)?.kittyImageCapture },
                    isOpen: isOpen,
                    onClose: {
                        model.closeTranscriptDrawer(sessionId: sessionId)
                        model.focusActiveTerminal()
                    },
                    workflow: model.sessionWorkflow(sessionId: sessionId),
                    operation: operation,
                    pendingUserInputs: model.sessionPendingUserInputs(sessionId: sessionId),
                    pendingElicitations: model.sessionPendingElicitations(sessionId: sessionId),
                    workflowProvider: { model.sessionWorkflow(sessionId: sessionId) },
                    operationProvider: { model.sessionOperationProjection(sessionId: sessionId) },
                    workingModelProvider: { model.sessionWorkingModel(sessionId: sessionId) },
                    promptComposer: composer,
                    onAction: { action in
                        await model.performLocalSessionAction(
                            sessionId: sessionId,
                            action: action,
                            expectedConversationEpoch: (action.kind == .send && action.attachmentIds?.isEmpty == false)
                                ? (composer.attachedEpoch ?? operation.conversationEpoch)
                                : operation.conversationEpoch
                        )
                    },
                    onAnswerUserInput: { answer in
                        await model.performLocalUserInputAnswer(sessionId: sessionId, answer: answer)
                    },
                    onAnswerElicitation: { answer in
                        await model.performLocalElicitationAnswer(sessionId: sessionId, answer: answer)
                    },
                    onPreview: onPreview
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOpen)
                .id(sessionId)
            }
        }
        // Opening a parked session resumes it once it has stayed on screen for 2 s.
        // Parking the session on screen doesn't change the id, so it stays parked.
        .task(id: model.globalSelectedSessionId) {
            guard let sessionId = model.globalSelectedSessionId,
                  model.parkedState(sessionId) == .parked else { return }
            try? await ContinuousClock().sleep(until: .now.advanced(by: .seconds(2)))
            if !Task.isCancelled { model.resumeParkedSession(sessionId) }
        }
    }
}

/// Stands in for the terminal of a session whose Copilot is parked.
private struct ParkedSessionPlaceholder: View {
    let model: AppModel
    let sessionId: String
    let state: ParkedSession.State

    private var text: (title: String, detail: String) {
        switch state {
        case .parking: ("Parking…", "Copilot is quitting in this session.")
        case .parked: ("Parked to free memory.", "Copilot starts again when you resume this session.")
        case .resuming: ("Resuming…", "Copilot is starting again. This takes a few seconds.")
        case .failed: ("Couldn't resume", "Copilot didn't start in this session. Nothing was lost.")
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(text.title).font(.title3.weight(.semibold))
            Text(text.detail).foregroundStyle(StudioStyle.secondaryText)
            HStack(spacing: 10) {
                switch state {
                case .parked:
                    Button("Resume") { model.resumeParkedSession(sessionId) }
                case .failed:
                    Button("Try Again") { model.resumeParkedSession(sessionId) }
                    Button("Open Terminal") { model.openParkedTerminal(sessionId) }
                case .parking, .resuming:
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioStyle.raised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("parked-session-placeholder")
    }
}

struct SessionBrowser: View {
    @ObservedObject var model: AppModel
    @Binding var showsProjects: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    showsProjects.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(showsProjects ? "Hide Projects (⌘0)" : "Show Projects (⌘0)")
                .accessibilityLabel(showsProjects ? "Hide Projects" : "Show Projects")
                .accessibilityIdentifier("toggle-projects")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Sessions").font(.headline)
                    Text(model.selectedProject?.name ?? "No project selected")
                        .font(.caption)
                        .foregroundStyle(StudioStyle.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let project = model.selectedProject {
                    SessionCreationButtons(model: model, project: project)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 56)
            Divider()
            if let project = model.selectedProject {
                SessionList(
                    model: model,
                    project: project,
                    showTabNumbers: model.numberHint == .tabs,
                    expandedParentIds: model.expandedParentSessionIds
                )
                    .id(project.id)
            } else {
                ContentUnavailableView("Choose a project", systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(StudioStyle.chrome)
    }
}

/// A row's Restart Session, disabled while `/restart` can't run in that session.
/// A view of its own, so that is judged when the row's menu is built rather
/// than for every row each time the list renders.
private struct RestartSessionMenuItem: View {
    @ObservedObject var model: AppModel
    let sessionId: String

    var body: some View {
        Button("Restart Session") { model.restartSession(sessionId) }
            .disabled(model.slashCommandBlockedReason(sessionId: sessionId) != nil)
    }
}

private struct SessionList: View {
    let model: AppModel
    let project: Project
    let showTabNumbers: Bool
    let expandedParentIds: Set<String>
    @AppStorage(SessionParking.settingKey) private var parkIdleSessions = SessionParking.off
    @State private var draggedSession: Session?
    @State private var dropTarget: SessionDropTarget?

    var body: some View {
        let displayItems = project.sessionDisplayItems(
            expandedParentIds: expandedParentIds
        )
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if project.sessions.isEmpty {
                        ContentUnavailableView(
                            "No sessions yet", systemImage: "terminal",
                            description: Text("Start Copilot or a terminal for this project.")
                        )
                    }
                    let hosts = model.availableHosts
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                        let session = item.session
                        SessionRow(
                            session: session,
                            hostDisplayName: session.hostId.flatMap { raw in
                                guard !raw.isEmpty else { return nil }
                                return SSHHostCatalog.resolve(hostId: raw, in: hosts)?.displayName ?? raw
                            },
                            isActive: session.id == project.selectedSessionId,
                            number: index < 9 ? index + 1 : nil,
                            showNumber: showTabNumbers,
                            isChild: item.isChild,
                            childSummary: item.childSummary,
                            isExpanded: item.isExpanded,
                            isDropTarget: dropTarget == .group(session.id),
                            onToggleExpand: item.childSummary != nil ? {
                                model.toggleParentSessionExpanded(session.id)
                            } : nil,
                            onSelect: {
                                model.selectSession(projectId: project.id, sessionId: session.id)
                                model.focusActiveTerminal()
                            },
                            onClose: { model.requestCloseSession(projectId: project.id, sessionId: session.id) }
                        )
                        .equatable()
                        .id(session.id)
                        .contextMenu {
                            if item.childSummary != nil {
                                Button(item.isExpanded ? "Collapse Children" : "Expand Children") {
                                    model.toggleParentSessionExpanded(session.id)
                                }
                                Divider()
                            }
                            if item.isChild {
                                Button("Ungroup from Parent") {
                                    model.ungroupSession(projectId: project.id, sessionId: session.id)
                                }
                            }
                            if item.childSummary == nil {
                                let candidateParents = project.sessions.filter {
                                    $0.id != session.id
                                        && $0.parentSessionId == nil
                                        && $0.id != item.effectiveParentSessionId
                                }
                                if !candidateParents.isEmpty {
                                    Menu("Group Under Parent") {
                                        ForEach(candidateParents) { parent in
                                            Button(parent.title) {
                                                model.groupSessionUnderParent(
                                                    projectId: project.id,
                                                    sessionId: session.id,
                                                    parentSessionId: parent.id
                                                )
                                            }
                                        }
                                    }
                                }
                                if item.isChild || !candidateParents.isEmpty {
                                    Divider()
                                }
                            }
                            let prKeys = session.effectivePullRequestKeys
                            if !prKeys.isEmpty {
                                ForEach(prKeys, id: \.self) { key in
                                    if let urlString = RemotePullRequestsContract.pullRequestURL(for: key),
                                       let url = URL(string: urlString) {
                                        Button("Open Pull Request \(RemotePullRequestsContract.shortDisplayLabel(for: key))") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                }
                                Divider()
                            }
                            if model.startingPrompt(for: session.id) != nil {
                                Button("Copy Starting Prompt") { model.copyStartingPrompt(for: session.id) }
                                Button("View Starting Prompt…") { model.presentStartingPrompt(for: session.id) }
                                Divider()
                            }
                            if session.offersMarkAsRead {
                                Button("Mark as Read") { model.markSessionRead(sessionId: session.id) }
                            } else {
                                Button("Mark as Unread") { model.markSessionUnread(sessionId: session.id) }
                            }
                            Divider()
                            // The Session menu's items, for this row rather than the selected one.
                            RestartSessionMenuItem(model: model, sessionId: session.id)
                            if parkIdleSessions != SessionParking.off {
                                Button("Park Session") { model.requestParkSession(session) }
                                    .disabled(session.parked != nil)
                            }
                            Button("End Session", role: .destructive) {
                                model.requestCloseSession(projectId: project.id, sessionId: session.id)
                            }
                        }
                        .overlay(alignment: .top) {
                            insertionBar.opacity(dropTarget == .reorder(session.id) ? 1 : 0).offset(y: -3)
                        }
                        .onDrag {
                            draggedSession = session
                            dropTarget = nil
                            return NSItemProvider(object: session.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: SessionDropDelegate(
                            targetId: session.id, dragged: $draggedSession,
                            dropTarget: $dropTarget, model: model, project: project))
                    }
                    Color.clear
                        .frame(height: 32)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) {
                            insertionBar.opacity(dropTarget == .reorder("") ? 1 : 0)
                        }
                        .onDrop(of: [.text], delegate: SessionDropDelegate(
                            targetId: "", dragged: $draggedSession,
                            dropTarget: $dropTarget, model: model, project: project))
                }
                .padding(10)
            }
            .onChange(of: project.selectedSessionId, initial: true) { _, id in
                if let id { proxy.scrollTo(id, anchor: nil) }
            }
        }
        .accessibilityLabel("Sessions in \(project.name)")
    }

    private var insertionBar: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(height: 3)
    }
}

private struct SessionCreationButtons: View {
    @ObservedObject var model: AppModel
    let project: Project

    var body: some View {
        HStack(spacing: 0) {
            Button { model.addCopilotSessionInteractive(toProjectId: project.id) } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help("New Copilot Session (⌘T)")
            .accessibilityLabel("New Copilot Session")

            Divider().frame(height: 14)

            Menu {
                Button("Start with Prompt…") {
                    model.addCopilotSessionInteractive(toProjectId: project.id, withPrompt: true)
                }
                Button("New Terminal") { model.addSession(toProjectId: project.id) }
                Button("Review Pull Request…", systemImage: "checkmark.shield") {
                    model.addAdversarialReviewSessionInteractive(toProjectId: project.id)
                }
                let projectClosedItems = model.recentlyClosedSessionItems(forProjectId: project.id)
                if !projectClosedItems.isEmpty {
                    Divider()
                    Menu("Recently Closed Sessions") {
                        Button("Reopen Last Closed Session") {
                            _ = model.reopenClosedSession(inProjectId: project.id)
                        }
                        Divider()
                        ForEach(projectClosedItems) { item in
                            Button(item.title) {
                                _ = model.reopenClosedSession(id: item.id)
                            }
                        }
                    }
                }
                if model.availableHosts.count > 1 || project.defaultHostId != nil {
                    Divider()
                    ForEach(model.availableHosts) { host in
                        Menu("Run on \(host.displayName)") {
                            Button("New Copilot Session") {
                                model.addCopilotSessionInteractive(toProjectId: project.id, hostId: host.id)
                            }
                            Button("Start with Prompt…") {
                                model.addCopilotSessionInteractive(
                                    toProjectId: project.id,
                                    withPrompt: true,
                                    hostId: host.id
                                )
                            }
                            Button("New Terminal") {
                                model.addSession(toProjectId: project.id, hostId: host.id)
                            }
                            Button("Review Pull Request…") {
                                model.addAdversarialReviewSessionInteractive(
                                    toProjectId: project.id,
                                    hostId: host.id
                                )
                            }
                        }
                    }
                    Divider()
                    Menu("Default Host") {
                        let currentHostId = model.effectiveHostId(forProjectId: project.id)
                        ForEach(model.availableHosts) { host in
                            Button {
                                model.setProjectDefaultHost(project.id, hostId: host.id)
                            } label: {
                                if currentHostId.caseInsensitiveCompare(host.id) == .orderedSame {
                                    Label(host.displayName, systemImage: "checkmark")
                                } else {
                                    Text(host.displayName)
                                }
                            }
                        }
                    }
                }
                Divider()
                Menu("Fleet Actions") {
                    Button("Bounce Idle Sessions") {
                        model.bounceIdleSessions(inProjectId: project.id)
                    }
                    Button("Mark All Sessions as Read") {
                        model.markAllSessionsRead(inProjectId: project.id)
                    }
                }
                Divider()
                SSHHostsSettingsMenu(model: model)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Session Options")
            .accessibilityLabel("More Session Options")
        }
        .hoverHighlight()
    }
}

struct HoverHighlightModifier: ViewModifier {
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            // Square, so it doesn't cut the corners off the button's own hit area. It can't widen
            // that area: a plain button only clicks on its label's shape.
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlightModifier())
    }
}

/// Visual and semantic outcome for a drag over a row (or the end-of-list spacer)
/// in `SessionList`: `.reorder` inserts before `targetId` (or appends when empty),
/// and `.group` attaches the dragged session under `targetId`.
enum SessionDropTarget: Equatable {
    case reorder(String)
    case group(String)

    var targetId: String {
        switch self {
        case .reorder(let id), .group(let id):
            return id
        }
    }
}

/// Near a row's top edge inserts before that row; the middle of a row groups under
/// that session when `Project.canGroupSession` allows it and falls back to sibling
/// reorder otherwise; an empty target appends to the list.
struct SessionDropDelegate: DropDelegate {
    static let reorderZoneHeight: CGFloat = 14

    let targetId: String
    @Binding var dragged: Session?
    @Binding var dropTarget: SessionDropTarget?
    let model: AppModel
    let project: Project

    static func resolveTarget(
        project: Project,
        draggedId: String?,
        targetId: String,
        locationY: CGFloat
    ) -> SessionDropTarget? {
        guard let draggedId,
              draggedId != targetId,
              project.sessions.contains(where: { $0.id == draggedId }) else {
            return nil
        }
        guard !targetId.isEmpty else { return .reorder("") }
        guard project.sessions.contains(where: { $0.id == targetId }) else { return nil }
        let effectiveParents = project.effectiveParentSessionIdsBySessionId()
        let canReorder = effectiveParents[draggedId] == effectiveParents[targetId]
        if locationY >= reorderZoneHeight,
           project.canGroupSession(draggedId, underParent: targetId, effectiveParents: effectiveParents) {
            return .group(targetId)
        }
        return canReorder ? .reorder(targetId) : nil
    }

    private func resolvedTarget(for info: DropInfo) -> SessionDropTarget? {
        Self.resolveTarget(
            project: project,
            draggedId: dragged?.id,
            targetId: targetId,
            locationY: info.location.y
        )
    }

    func dropEntered(info: DropInfo) {
        dropTarget = resolvedTarget(for: info)
    }
    func dropExited(info: DropInfo) {
        if dropTarget?.targetId == targetId { dropTarget = nil }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let resolved = resolvedTarget(for: info)
        dropTarget = resolved
        return DropProposal(operation: resolved != nil ? .move : .cancel)
    }
    static func perform(
        _ target: SessionDropTarget,
        draggedId: String,
        projectId: String,
        model: AppModel
    ) {
        switch target {
        case .reorder(let beforeId):
            model.moveSession(
                projectId: projectId,
                draggedId: draggedId,
                beforeId: beforeId.isEmpty ? nil : beforeId
            )
        case .group(let parentId):
            model.groupSessionUnderParent(
                projectId: projectId,
                sessionId: draggedId,
                parentSessionId: parentId
            )
        }
    }
    func performDrop(info: DropInfo) -> Bool {
        let resolved = resolvedTarget(for: info)
        if let dragged, let resolved {
            Self.perform(resolved, draggedId: dragged.id, projectId: project.id, model: model)
        }
        dragged = nil
        dropTarget = nil
        return resolved != nil
    }
}

/// Drop target for a session tab dragged onto a project row in the sidebar —
/// moves that session into the project. `dropTargetProjectId` drives the row's
/// drag-over highlight. A project-reorder drag (List `.onMove`) doesn't vend a
/// `.text` item, so `validateDrop` ignores it and the two gestures don't collide.
private struct ProjectDropDelegate: DropDelegate {
    let projectId: String
    @Binding var dropTargetProjectId: String?
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { dropTargetProjectId = projectId }
    func dropExited(info: DropInfo) {
        if dropTargetProjectId == projectId { dropTargetProjectId = nil }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        dropTargetProjectId = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let sid = object as? String else { return }
            DispatchQueue.main.async { model.moveSession(toProjectId: projectId, draggedId: sid) }
        }
        return true
    }
}

private struct SessionRowChromeModifier: ViewModifier {
    let isActive: Bool
    var isDropTarget: Bool = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isDropTarget
                            ? Color.accentColor.opacity(0.15)
                            : isActive ? StudioStyle.selection : isHovering ? StudioStyle.raised : .clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isDropTarget ? Color.accentColor : isActive ? StudioStyle.selectionEdge : .clear,
                        lineWidth: isDropTarget ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

struct HostBadge: View, Equatable {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(StudioStyle.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(StudioStyle.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
            .help("Running on \(name)")
    }
}

struct SessionMemoryBadge: View, Equatable {
    let bytes: Int64

    static func formattedBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        if bytes >= 1_000_000_000 {
            let tenths = Int((Double(bytes) / 100_000_000.0).rounded())
            if tenths % 10 == 0 {
                return "\(tenths / 10) GB"
            }
            return "\(tenths / 10).\(tenths % 10) GB"
        }
        let megabytes = max(1, Int((Double(bytes) / 1_000_000.0).rounded()))
        return "\(megabytes) MB"
    }

    var body: some View {
        let label = Self.formattedBytes(bytes)
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(StudioStyle.secondaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(StudioStyle.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
            .help("Session memory footprint: \(label)")
            .accessibilityIdentifier("session-memory-badge")
    }
}

struct RunningElapsedLabel: View, Equatable {
    let startedAtMilliseconds: Int64

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let nowMs = Int64(context.date.timeIntervalSince1970 * 1_000)
            if let elapsed = RemotePullRequestsContract.formattedElapsedDuration(
                fromMilliseconds: startedAtMilliseconds,
                nowMilliseconds: nowMs
            ) {
                Text(elapsed)
                    .monospacedDigit()
                    .foregroundStyle(.green.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("session-running-elapsed-label")
            }
        }
    }
}

struct PullRequestBadge: View, Equatable {
    let key: String

    var body: some View {
        let shortLabel = RemotePullRequestsContract.shortDisplayLabel(for: key)
        Button {
            if let urlString = RemotePullRequestsContract.pullRequestURL(for: key),
               let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 9, weight: .medium))
                Text(shortLabel)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(StudioStyle.secondaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(StudioStyle.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Open \(key) on GitHub")
        .accessibilityIdentifier("session-pr-badge-\(key)")
    }
}

struct SessionRow: View, Equatable {
    let session: Session
    var hostDisplayName: String? = nil
    let isActive: Bool
    var number: Int? = nil
    var showNumber: Bool = false
    var isChild: Bool = false
    var childSummary: SessionChildSummary? = nil
    var isExpanded: Bool = false
    var isDropTarget: Bool = false
    var onToggleExpand: (() -> Void)? = nil
    let onSelect: () -> Void
    let onClose: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isActive == rhs.isActive
            && lhs.number == rhs.number
            && lhs.showNumber == rhs.showNumber
            && lhs.hostDisplayName == rhs.hostDisplayName
            && lhs.isChild == rhs.isChild
            && lhs.childSummary == rhs.childSummary
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isDropTarget == rhs.isDropTarget
            && lhs.session.id == rhs.session.id
            && lhs.session.title == rhs.session.title
            && lhs.session.hostId == rhs.session.hostId
            && lhs.session.memoryUsageBytes == rhs.session.memoryUsageBytes
            && lhs.session.parked == rhs.session.parked
            && lhs.session.statusText == rhs.session.statusText
            && lhs.session.displayStatus == rhs.session.displayStatus
            && lhs.session.effectiveRunningStartedAtMilliseconds == rhs.session.effectiveRunningStartedAtMilliseconds
            && lhs.session.effectivePullRequestKeys == rhs.session.effectivePullRequestKeys
            && lhs.session.failedRequest == rhs.session.failedRequest
            && lhs.session.finishedUnseen == rhs.session.finishedUnseen
            && lhs.session.isUnread == rhs.session.isUnread
            && lhs.session.markedUnread == rhs.session.markedUnread
            && lhs.session.hasBackgroundWork == rhs.session.hasBackgroundWork
            && lhs.session.schedules == rhs.session.schedules
    }

    var showsUnreadIndicator: Bool {
        // Avoid duplicating the idle completion dot unless the tab-number hint,
        // a manual unread mark, or a failure indicator applies.
        session.isUnread && (showNumber || session.displayStatus != .idle
            || !session.finishedUnseen || session.failedRequest != nil || session.markedUnread)
    }

    var accessibilityStatus: String { accessibilityStatus() }

    func accessibilityStatus(nowMilliseconds: Int64 = SessionArtifacts.currentStatusTimestamp()) -> String {
        var states: [String] = []
        if isActive { states.append("Selected") }
        if isChild { states.append("Child session") }
        let elapsed = session.effectiveRunningStartedAtMilliseconds.flatMap {
            RemotePullRequestsContract.formattedElapsedDuration(fromMilliseconds: $0, nowMilliseconds: nowMilliseconds)
        }
        states.append(elapsed.map { "\(stateLabel) \($0)" } ?? stateLabel)
        if let hostLabel = hostDisplayName ?? session.hostId, !hostLabel.isEmpty {
            states.append("Running on \(hostLabel)")
        }
        if let memoryBytes = session.memoryUsageBytes, memoryBytes > 0 {
            states.append("Memory \(SessionMemoryBadge.formattedBytes(memoryBytes))")
        }
        if let childSummary {
            states.append(childSummary.label)
            states.append(isExpanded ? "Expanded" : "Collapsed")
        }
        if session.isUnread { states.append("Unread") }
        if session.hasBackgroundWork { states.append("Background work active") }
        if !session.schedules.isEmpty { states.append("Scheduled work") }
        return states.joined(separator: ", ")
    }

    var stateLabel: String { session.attentionLabel }

    var stateColor: Color {
        switch session.displayStatus {
        case .running: return .green
        case .waiting: return .orange
        case .idle:
            if session.failedRequest != nil { return .red }
            if session.finishedUnseen { return .blue }
            if session.hasBackgroundWork { return .purple }
            return StudioStyle.secondaryText
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if isChild {
                RoundedRectangle(cornerRadius: 1)
                    .fill(StudioStyle.secondaryText.opacity(0.35))
                    .frame(width: 2)
                    .padding(.vertical, 4)
                    .padding(.leading, 10)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                HStack(alignment: .top, spacing: 7) {
                    ZStack {
                        SessionStateIndicator(session: session)
                            .equatable()
                            .opacity(showNumber ? 0 : 1)
                        if showNumber, let number {
                            NumberBadge(number: number)
                        }
                    }
                    .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.title)
                            .font(.body.weight(.medium))
                            .lineLimit(2)
                            .help(session.statusText ?? session.title)
                        let showsRunningElapsed = session.displayStatus == .running
                            && session.effectiveRunningStartedAtMilliseconds != nil
                        let showsBackgroundBadge = session.hasBackgroundWork
                            && SessionStateIndicator.symbolName(for: session) != "sparkles"
                        if showsRunningElapsed
                            || (session.memoryUsageBytes ?? 0) > 0
                            || showsBackgroundBadge
                            || !session.schedules.isEmpty
                            || showsUnreadIndicator {
                            HStack(spacing: 6) {
                                if showsRunningElapsed,
                                   let startedAt = session.effectiveRunningStartedAtMilliseconds {
                                    RunningElapsedLabel(startedAtMilliseconds: startedAt)
                                }
                                if let memoryBytes = session.memoryUsageBytes, memoryBytes > 0 {
                                    SessionMemoryBadge(bytes: memoryBytes)
                                }
                                if showsBackgroundBadge { BackgroundWorkBadge() }
                                if !session.schedules.isEmpty { ScheduleBadge(schedules: session.schedules) }
                                if showsUnreadIndicator {
                                    UnreadBadge(isMarkedUnread: session.markedUnread)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(StudioStyle.secondaryText)
                        }
                        if let childSummary {
                            Text(childSummary.label)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(StudioStyle.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                )
                                .contentShape(Capsule(style: .continuous))
                                .onTapGesture { onToggleExpand?() }
                                .help("\(isExpanded ? "Collapse" : "Expand") (\(childSummary.label))")
                                .accessibilityIdentifier("session-child-summary")
                        }
                        let prKeys = Array(session.effectivePullRequestKeys.prefix(2))
                        let hostLabel = (hostDisplayName ?? session.hostId).flatMap { $0.isEmpty ? nil : $0 }
                        if hostLabel != nil || !prKeys.isEmpty {
                            HStack(spacing: 5) {
                                if let hostLabel {
                                    HostBadge(name: hostLabel)
                                }
                                ForEach(prKeys, id: \.self) { key in
                                    PullRequestBadge(key: key)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 1)
                        .onEnded(onSelect)
                        .simultaneously(with: TapGesture(count: 2).onEnded {
                            // Finish the second click's selection before removing its row.
                            DispatchQueue.main.async(execute: onClose)
                        })
                )
                if let childSummary {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { onToggleExpand?() }
                        .help("\(isExpanded ? "Collapse" : "Expand") (\(childSummary.label))")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("End \(session.title)")
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .modifier(SessionRowChromeModifier(isActive: isActive, isDropTarget: isDropTarget))
        }
        .accessibilityRepresentation {
            HStack {
                if childSummary != nil, let onToggleExpand {
                    Button(
                        isExpanded ? "Collapse \(session.title) children" : "Expand \(session.title) children",
                        action: onToggleExpand
                    )
                }
                if session.effectiveRunningStartedAtMilliseconds != nil {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Button(session.title, action: onSelect)
                            .accessibilityValue(accessibilityStatus(nowMilliseconds: Int64(context.date.timeIntervalSince1970 * 1_000)))
                            .accessibilityAddTraits(isActive ? .isSelected : [])
                    }
                } else {
                    Button(session.title, action: onSelect)
                        .accessibilityValue(accessibilityStatus)
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                }
                ForEach(Array(session.effectivePullRequestKeys.prefix(2)), id: \.self) { key in
                    if let urlString = RemotePullRequestsContract.pullRequestURL(for: key),
                       let url = URL(string: urlString) {
                        Button("Open \(key) on GitHub") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("End \(session.title)", action: onClose)
            }
        }
    }
}
