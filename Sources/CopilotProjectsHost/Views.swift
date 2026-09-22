import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CopilotProjectsCore

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
        .sheet(item: $input.imagePreview) { item in
            TranscriptImagePreview(item: item) { input.imagePreview = nil }
        }
        .onChange(of: previewSessionId) { _, sessionId in
            if let preview = input.imagePreview, preview.id.sessionId != sessionId {
                input.imagePreview = nil
            }
        }
        .onDisappear { input.imagePreview = nil }
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
        HStack(spacing: 12) {
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
/// (indigo), then the waiting (orange) and ready (blue) counts; "all idle" when
/// nothing is active. (No spinner here — an NSProgressIndicator breaks Auto Layout
/// inside the title-bar accessory's hosting view.)
struct FleetStatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let running = model.totalRunning
        let background = model.totalBackgroundWork
        let scheduled = model.totalScheduled
        let waiting = model.totalWaiting
        let ready = model.totalReady
        HStack(spacing: 10) {
            if running > 0 { Text("\(running) running").foregroundStyle(.green) }
            if background > 0 {
                HStack(spacing: 4) {
                    BackgroundWorkBadge()
                    Text("\(background) background").foregroundStyle(.purple)
                }
            }
            if scheduled > 0 { Text("\(scheduled) scheduled").foregroundStyle(.indigo) }
            if waiting > 0 { Text("\(waiting) waiting").foregroundStyle(.orange) }
            if ready > 0 { Text("\(ready) ready").foregroundStyle(.blue) }
            if running == 0, background == 0, scheduled == 0, waiting == 0, ready == 0 {
                Text("all idle").foregroundStyle(StudioStyle.secondaryText)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .allowsHitTesting(false)
    }
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
        List(selection: Binding(
            get: { model.selectedProjectId },
            set: { model.selectProject($0) }
        )) {
            ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                ProjectRow(
                    project: project,
                    number: index < 9 ? index + 1 : nil,
                    showNumber: model.numberHint == .projects,
                    isDropTarget: dropTargetProjectId == project.id
                )
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

struct ProjectRow: View {
    let project: Project
    var number: Int? = nil
    var showNumber: Bool = false
    var isDropTarget: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .help(project.name)
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

    // Keep one compact status line so changing activity does not move projects.
    @ViewBuilder private var statusLine: some View {
        let running = project.runningCount
        let background = project.backgroundWorkCount
        let scheduled = project.scheduledCount
        let waiting = project.waitingCount
        let descriptions = [
            (waiting, "waiting for input"), (running, "running"),
            (background, "background"), (scheduled, "scheduled"),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        if running > 0 || background > 0 || scheduled > 0 || waiting > 0 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    if running > 0 { activityCount(running, "play.fill", .green) }
                    if background > 0 { activityCount(background, "person.2.fill", .purple) }
                    if scheduled > 0 { activityCount(scheduled, "clock", .indigo) }
                    if waiting > 0 { activityCount(waiting, "exclamationmark.circle", .orange) }
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
/// (running); orange means it's waiting on your input; blue means it has finished
/// and you haven't viewed it yet ("ready for interaction"); idle shows nothing.
/// The 9pt frame keeps the slot a constant size whether or not a dot is shown.
/// SessionRow suppresses its separate unread dot while this indicator is blue.
struct SessionStateIndicator: View {
    let session: Session

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
            case .none:
                Color.clear
            }
        }
        .frame(width: 9, height: 9)
        .help(help)
    }

    private enum Kind { case busy, dot(Color), none }

    private var kind: Kind {
        switch session.status {
        case .running: return .busy
        case .waiting: return .dot(.orange)
        case .idle: return session.finishedUnseen ? .dot(.blue) : .none
        }
    }

    private var help: String {
        switch session.status {
        case .running: return "running"
        case .waiting: return "waiting for input"
        case .idle: return session.finishedUnseen ? "finished — ready for you" : "idle"
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
                TranscriptOverlay(
                    controller: transcript,
                    imageCapture: { model.terminalView(for: sessionId)?.kittyImageCapture },
                    isOpen: model.isTranscriptDrawerOpen(sessionId: sessionId),
                    onClose: { model.closeTranscriptDrawer(sessionId: sessionId) },
                    workflow: model.sessionWorkflow(sessionId: sessionId),
                    operation: model.sessionOperationProjection(sessionId: sessionId),
                    onAction: { action in
                        await model.performLocalSessionAction(sessionId: sessionId, action: action)
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
                SessionList(model: model, project: project)
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
    @ObservedObject var model: AppModel
    let project: Project
    @State private var draggedSession: Session?
    @State private var dropTargetId: String?     // a session id, or "" for end-of-list

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    if project.sessions.isEmpty {
                        ContentUnavailableView(
                            "No sessions yet", systemImage: "terminal",
                            description: Text("Start Copilot or a terminal for this project.")
                        )
                    }
                    ForEach(Array(project.sessions.enumerated()), id: \.element.id) { index, session in
                        SessionRow(
                            session: session,
                            isActive: session.id == project.selectedSessionId,
                            number: index < 9 ? index + 1 : nil,
                            showNumber: model.numberHint == .tabs,
                            onSelect: {
                                model.selectSession(projectId: project.id, sessionId: session.id)
                                model.focusActiveTerminal()
                            },
                            onClose: { model.requestCloseSession(projectId: project.id, sessionId: session.id) }
                        )
                        .id(session.id)
                        .contextMenu {
                            if model.startingPrompt(for: session.id) != nil {
                                Button("Copy Starting Prompt") { model.copyStartingPrompt(for: session.id) }
                                Divider()
                            }
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
                            dropTargetId: $dropTargetId, model: model, projectId: project.id))
                    }
                    Color.clear
                        .frame(height: 32)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) {
                            insertionBar.opacity(dropTargetId == "" ? 1 : 0)
                        }
                        .onDrop(of: [.text], delegate: SessionDropDelegate(
                            targetId: "", dragged: $draggedSession,
                            dropTargetId: $dropTargetId, model: model, projectId: project.id))
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
private struct SessionDropDelegate: DropDelegate {
    let targetId: String
    @Binding var dragged: Session?
    @Binding var dropTargetId: String?
    let model: AppModel
    let projectId: String

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged.id != targetId else { dropTargetId = nil; return }
        dropTargetId = targetId
    }
    func dropExited(info: DropInfo) {
        if dropTargetId == targetId { dropTargetId = nil }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        if let dragged {
            model.moveSession(projectId: projectId, draggedId: dragged.id,
                              beforeId: targetId.isEmpty ? nil : targetId)
        }
        dragged = nil
        dropTargetId = nil
        return true
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

struct SessionRow: View {
    let session: Session
    let isActive: Bool
    var number: Int? = nil
    var showNumber: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var showsUnreadIndicator: Bool {
        // Avoid duplicating the idle completion dot unless the tab-number hint hides it.
        session.hasUnread && (showNumber || session.status != .idle || !session.finishedUnseen)
    }

    var accessibilityStatus: String {
        var states: [String] = []
        if isActive { states.append("Selected") }
        states.append(stateLabel)
        if session.hasUnread { states.append("Unread") }
        if session.hasBackgroundWork { states.append("Background work active") }
        if !session.schedules.isEmpty { states.append("Scheduled work") }
        return states.joined(separator: ", ")
    }

    var stateLabel: String {
        switch session.status {
        case .running: return "Running"
        case .waiting: return "Waiting for input"
        case .idle: return session.finishedUnseen ? "Finished" : "Idle"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                ZStack {
                    SessionStateIndicator(session: session)
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
                        if session.hasBackgroundWork { BackgroundWorkBadge() }
                        if !session.schedules.isEmpty { ScheduleBadge(schedules: session.schedules) }
                        if showsUnreadIndicator {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(.blue)
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(StudioStyle.secondaryText)
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
        .accessibilityRepresentation {
            HStack {
                Button(session.title, action: onSelect)
                    .accessibilityValue(accessibilityStatus)
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                Button("End \(session.title)", action: onClose)
            }
        }
    }
}
