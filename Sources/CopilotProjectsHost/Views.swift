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
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
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
        } else {
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
            Image(systemName: "terminal")
                .foregroundStyle(StudioStyle.secondaryText)
                .accessibilityHidden(true)
            if let sessionId = model.globalSelectedSessionId,
               let transcript = model.activeTranscriptController {
                TranscriptButton(
                    controller: transcript,
                    isOpen: model.isTranscriptDrawerOpen(sessionId: sessionId),
                    hasWorkflow: model.sessionWorkflow(sessionId: sessionId) != nil,
                    onOpen: { model.openTranscriptDrawer(sessionId: sessionId) }
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
                pill(.running, help: "Jump to next running session") {
                    Text("\(running) running").foregroundStyle(.green)
                }
            }
            if background > 0 {
                pill(.background, help: "Jump to next background-work session") {
                    HStack(spacing: 4) {
                        BackgroundWorkBadge()
                        Text("\(background) background").foregroundStyle(.purple)
                    }
                }
            }
            if scheduled > 0 {
                pill(.scheduled, help: "Jump to next scheduled session") {
                    Text("\(scheduled) scheduled").foregroundStyle(.indigo)
                }
            }
            if waiting > 0 {
                pill(.waiting, help: "Jump to next session waiting for input (⇧⌘A)") {
                    Text("\(waiting) waiting").foregroundStyle(.orange)
                }
            }
            if failed > 0 {
                pill(.failed, help: "Jump to next session with a failed request (⇧⌘A)") {
                    Text("\(failed) failed").foregroundStyle(.red)
                }
            }
            if ready > 0 {
                pill(.ready, help: "Jump to next finished session (⇧⌘A)") {
                    Text("\(ready) ready").foregroundStyle(.blue)
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

    private func pill<Label: View>(
        _ kind: FleetActivityKind,
        help: String,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            model.selectNextSession(matching: kind)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .help(help)
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
        if let worst = hosts.max(by: { $0.level < $1.level }), worst.level > .healthy {
            let reason = worst.statusSummary ?? worst.level.rawValue.capitalized
            raw = hosts.count > 1 ? "\(worst.displayName): \(reason)" : reason
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
        .help("Show host health details")
        .accessibilityLabel("Host health: \(level.rawValue.capitalized). \(label)")
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
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
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
                    if running > 0 { activityCount(running, "play.fill", .green) }
                    if background > 0 { activityCount(background, "person.2.fill", .purple) }
                    if scheduled > 0 { activityCount(scheduled, "clock", .indigo) }
                    if waiting > 0 { activityCount(waiting, "exclamationmark.circle", .orange) }
                    // Same symbol as the session row's failure indicator.
                    if failed > 0 { activityCount(failed, "exclamationmark.circle.fill", .red) }
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

/// The indicator at the left of a session tab. A spinner means the agent is busy
/// (running); orange means it's waiting on your input; a red exclamation means
/// its latest request failed; blue means it has finished and you haven't viewed
/// it yet ("ready for interaction"); idle shows nothing.
/// The 9pt frame keeps the slot a constant size whether or not a dot is shown.
/// SessionRow suppresses its separate unread dot while this indicator is blue.
struct SessionStateIndicator: View, Equatable {
    let session: Session

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session.displayStatus == rhs.session.displayStatus
            && lhs.session.failedRequest == rhs.session.failedRequest
            && lhs.session.finishedUnseen == rhs.session.finishedUnseen
    }

    var body: some View {
        statusIndicator
    }

    private var statusIndicator: some View {
        Group {
            switch kind {
            case .busy:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            case .dot(let color):
                Circle()
                    .fill(color)
                    .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.red)
            case .none:
                Color.clear
            }
        }
        .frame(width: 9, height: 9)
        .help(help)
    }

    private enum Kind { case busy, dot(Color), failed, none }

    private var kind: Kind {
        switch session.displayStatus {
        case .running: return .busy
        case .waiting: return .dot(.orange)
        case .idle:
            if session.failedRequest != nil { return .failed }
            return session.finishedUnseen ? .dot(.blue) : .none
        }
    }

    private var help: String {
        switch session.displayStatus {
        case .running: return "running"
        case .waiting: return "waiting for input"
        case .idle:
            if let failure = session.failedRequest {
                return "request failed — \(failure.message)"
            }
            return session.finishedUnseen ? "finished — ready for you" : "idle"
        }
    }
}

/// Shown on a tab and its project's sidebar row while background work is active.
/// Sized to the reserved 9pt slot so the project name stays aligned.
struct BackgroundWorkBadge: View {
    var body: some View {
        Image(systemName: "person.2.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 9, height: 9)
            .foregroundStyle(.purple)
            .help("background work active")
    }
}

struct ScheduleBadge: View {
    let schedules: [TrackedSchedule]

    var body: some View {
        Image(systemName: "clock.arrow.circlepath")
            .resizable()
            .scaledToFit()
            .frame(width: 10, height: 10)
            .foregroundStyle(.indigo)
            .help(schedules.map(\.helpText).joined(separator: "\n\n"))
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
                hostedIds: model.hostedTerminals.map(\.id)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let sessionId = model.globalSelectedSessionId,
               let transcript = model.activeTranscriptController {
                let operation = model.sessionOperationProjection(sessionId: sessionId)
                let composer = model.sessionPromptComposer(sessionId: sessionId)
                TranscriptOverlay(
                    controller: transcript,
                    imageCapture: { model.terminalView(for: sessionId)?.kittyImageCapture },
                    isOpen: model.isTranscriptDrawerOpen(sessionId: sessionId),
                    onClose: { model.closeTranscriptDrawer(sessionId: sessionId) },
                    workflow: model.sessionWorkflow(sessionId: sessionId),
                    operation: operation,
                    workflowProvider: { model.sessionWorkflow(sessionId: sessionId) },
                    operationProvider: { model.sessionOperationProjection(sessionId: sessionId) },
                    promptComposer: composer,
                    onAction: { action in
                        await model.performLocalSessionAction(
                            sessionId: sessionId,
                            action: action,
                            expectedConversationEpoch: action.kind == .send
                                ? (composer.attachedEpoch ?? operation.conversationEpoch)
                                : operation.conversationEpoch
                        )
                    },
                    onPreview: onPreview
                )
                .id(sessionId)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value:
                    model.isTranscriptDrawerOpen(sessionId: sessionId))
            }
        }
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

private struct SessionList: View {
    let model: AppModel
    let project: Project
    let showTabNumbers: Bool
    let expandedParentIds: Set<String>
    @State private var draggedSession: Session?
    @State private var dropTargetId: String?     // a session id, or "" for end-of-list

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
                                Divider()
                            }
                            if model.startingPrompt(for: session.id) != nil {
                                Button("Copy Starting Prompt") { model.copyStartingPrompt(for: session.id) }
                                Divider()
                            }
                            if session.offersMarkAsRead {
                                Button("Mark as Read") { model.markSessionRead(sessionId: session.id) }
                            } else {
                                Button("Mark as Unread") { model.markSessionUnread(sessionId: session.id) }
                            }
                            Divider()
                            Button("End Session", role: .destructive) {
                                model.requestCloseSession(projectId: project.id, sessionId: session.id)
                            }
                        }
                        .overlay(alignment: .top) {
                            insertionBar.opacity(dropTargetId == session.id ? 1 : 0).offset(y: -3)
                        }
                        .onDrag {
                            draggedSession = session
                            dropTargetId = nil
                            return NSItemProvider(object: session.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: SessionDropDelegate(
                            targetId: session.id, dragged: $draggedSession,
                            dropTargetId: $dropTargetId, model: model, project: project))
                    }
                    Color.clear
                        .frame(height: 32)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) {
                            insertionBar.opacity(dropTargetId == "" ? 1 : 0)
                        }
                        .onDrop(of: [.text], delegate: SessionDropDelegate(
                            targetId: "", dragged: $draggedSession,
                            dropTargetId: $dropTargetId, model: model, project: project))
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
    let model: AppModel
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

private struct HoverHighlightModifier: ViewModifier {
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }
}

private extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlightModifier())
    }
}

/// A session id inserts before that row; an empty target appends to the list.
/// Top-level rows reorder among top-level rows; child rows reorder among siblings.
private struct SessionDropDelegate: DropDelegate {
    let targetId: String
    @Binding var dragged: Session?
    @Binding var dropTargetId: String?
    let model: AppModel
    let project: Project

    private var canDrop: Bool {
        guard let dragged, dragged.id != targetId else { return false }
        guard !targetId.isEmpty else { return true }
        return project.effectiveParentSessionId(for: dragged.id)
            == project.effectiveParentSessionId(for: targetId)
    }

    func dropEntered(info: DropInfo) {
        dropTargetId = canDrop ? targetId : nil
    }
    func dropExited(info: DropInfo) {
        if dropTargetId == targetId { dropTargetId = nil }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: canDrop ? .move : .cancel)
    }
    func performDrop(info: DropInfo) -> Bool {
        let allowed = canDrop
        if allowed, let dragged {
            model.moveSession(projectId: project.id, draggedId: dragged.id,
                              beforeId: targetId.isEmpty ? nil : targetId)
        }
        dragged = nil
        dropTargetId = nil
        return allowed
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
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? StudioStyle.selection : isHovering ? StudioStyle.raised : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive ? StudioStyle.selectionEdge : .clear, lineWidth: 1)
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

struct SessionRow: View, Equatable {
    let session: Session
    var hostDisplayName: String? = nil
    let isActive: Bool
    var number: Int? = nil
    var showNumber: Bool = false
    var isChild: Bool = false
    var childSummary: SessionChildSummary? = nil
    var isExpanded: Bool = false
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
            && lhs.session.id == rhs.session.id
            && lhs.session.title == rhs.session.title
            && lhs.session.hostId == rhs.session.hostId
            && lhs.session.memoryUsageBytes == rhs.session.memoryUsageBytes
            && lhs.session.statusText == rhs.session.statusText
            && lhs.session.displayStatus == rhs.session.displayStatus
            && lhs.session.failedRequest == rhs.session.failedRequest
            && lhs.session.finishedUnseen == rhs.session.finishedUnseen
            && lhs.session.isUnread == rhs.session.isUnread
            && lhs.session.hasBackgroundWork == rhs.session.hasBackgroundWork
            && lhs.session.schedules == rhs.session.schedules
    }

    var showsUnreadIndicator: Bool {
        // Avoid duplicating the idle completion dot unless the tab-number hint
        // or a failure indicator hides it.
        session.isUnread && (showNumber || session.displayStatus != .idle
            || !session.finishedUnseen || session.failedRequest != nil)
    }

    var accessibilityStatus: String {
        var states: [String] = []
        if isActive { states.append("Selected") }
        if isChild { states.append("Child session") }
        states.append(stateLabel)
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
                        HStack(spacing: 6) {
                            Text(stateLabel)
                            if let memoryBytes = session.memoryUsageBytes, memoryBytes > 0 {
                                SessionMemoryBadge(bytes: memoryBytes)
                            }
                            if session.hasBackgroundWork { BackgroundWorkBadge() }
                            if !session.schedules.isEmpty { ScheduleBadge(schedules: session.schedules) }
                            if showsUnreadIndicator {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundStyle(.blue)
                                    .accessibilityHidden(true)
                            }
                            if let childSummary {
                                Text(childSummary.label)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.primary.opacity(0.08))
                                    )
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(StudioStyle.secondaryText)
                        if let hostLabel = hostDisplayName ?? session.hostId, !hostLabel.isEmpty {
                            HostBadge(name: hostLabel)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    // Finish the second click's selection before removing its row.
                    DispatchQueue.main.async(execute: onClose)
                })
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
            .modifier(SessionRowChromeModifier(isActive: isActive))
        }
        .accessibilityRepresentation {
            HStack {
                if childSummary != nil, let onToggleExpand {
                    Button(
                        isExpanded ? "Collapse \(session.title) children" : "Expand \(session.title) children",
                        action: onToggleExpand
                    )
                }
                Button(session.title, action: onSelect)
                    .accessibilityValue(accessibilityStatus)
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                Button("End \(session.title)", action: onClose)
            }
        }
    }
}
