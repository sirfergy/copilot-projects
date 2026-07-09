import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CopilotProjectsCore

struct RootView: View {
    @ObservedObject var model: AppModel

    // Top strip in the window's title-bar region: the fleet status sits at the
    // right; the traffic lights float over the left. The session tabs live in a
    // separate thin row just below it — out of the window's drag region — so a
    // drag reorders them instead of moving the window. (Content in the title-bar
    // drag region always moves the window on macOS, so the tabs can't live there.)
    private let titleStripHeight: CGFloat = 38

    var body: some View {
        VStack(spacing: 0) {
            topStrip
            HSplitView {
                SidebarView(model: model)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                    .background(SplitViewAutosaver(name: "copilotmux.sidebar"))
                VStack(spacing: 0) {
                    tabRow
                    Divider()
                    DetailView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator())
    }

    private var topStrip: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            FleetStatusBar(model: model)
                .padding(.trailing, 12)
        }
        .frame(height: titleStripHeight)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabRow: some View {
        HStack(spacing: 0) {
            if let project = model.selectedProject, !project.sessions.isEmpty {
                SessionTabBar(model: model, project: project)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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
/// the running count (green), background-agent sessions (purple), then the waiting
/// (orange) and ready (blue) counts; "all idle" when nothing is active. (No spinner
/// here — an NSProgressIndicator breaks Auto Layout inside the title-bar accessory's
/// hosting view.)
struct FleetStatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let running = model.totalRunning
        let background = model.totalBackgroundAgents
        let scheduled = model.totalScheduled
        let waiting = model.totalWaiting
        let ready = model.totalReady
        HStack(spacing: 10) {
            if running > 0 { Text("\(running) running").foregroundStyle(.green) }
            if background > 0 {
                HStack(spacing: 4) {
                    BackgroundAgentsBadge()
                    Text("\(background) background").foregroundStyle(.purple)
                }
            }
            if scheduled > 0 { Text("\(scheduled) scheduled").foregroundStyle(.indigo) }
            if waiting > 0 { Text("\(waiting) waiting").foregroundStyle(.orange) }
            if ready > 0 { Text("\(ready) ready").foregroundStyle(.blue) }
            if running == 0, background == 0, scheduled == 0, waiting == 0, ready == 0 {
                Text("all idle").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
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
                        Button("New Session") { model.addSession(toProjectId: project.id) }
                        Button("Rename…") { model.renameProjectInteractive(project.id) }
                        Divider()
                        Button("Close Project", role: .destructive) {
                            model.closeProject(project.id)
                        }
                    }
            }
            .onMove { model.moveProjects(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    model.addProjectInteractive()
                } label: {
                    Label("New Project", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .controlSize(.large)
                .buttonStyle(.borderless)
                .hoverHighlight()

                Text("v\(CLIMain.versionNumber)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(8)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).lineLimit(1)
                Text("\(project.sessions.count) session\(project.sessions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .padding(.vertical, 2)
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

    // Its own line, always present (even when "idle"), so the row height never
    // changes as agents start/stop. Waiting is the actionable one, so it's orange;
    // running is muted; idle is fainter still.
    @ViewBuilder private var statusLine: some View {
        let running = project.runningCount
        let background = project.backgroundAgentCount
        let scheduled = project.scheduledCount
        let waiting = project.waitingCount
        if running > 0 || background > 0 || scheduled > 0 || waiting > 0 {
            HStack(spacing: 4) {
                if running > 0 { Text("\(running) running").foregroundStyle(.green) }
                if running > 0, background > 0 || scheduled > 0 || waiting > 0 {
                    Text("·").foregroundStyle(.tertiary)
                }
                if background > 0 { Text("\(background) background").foregroundStyle(.purple) }
                if background > 0, scheduled > 0 || waiting > 0 {
                    Text("·").foregroundStyle(.tertiary)
                }
                if scheduled > 0 { Text("\(scheduled) scheduled").foregroundStyle(.indigo) }
                if scheduled > 0, waiting > 0 { Text("·").foregroundStyle(.tertiary) }
                if waiting > 0 { Text("\(waiting) waiting").foregroundStyle(.orange) }
            }
        } else {
            Text("idle").foregroundStyle(.tertiary)
        }
    }
}

/// The indicator at the left of a session tab. A spinner means the agent is busy
/// (running); orange means it's waiting on your input; blue means it has finished
/// and you haven't viewed it yet ("ready for interaction"); idle shows nothing.
/// The 9pt frame keeps the slot a constant size whether or not a dot is shown.
struct SessionTabIndicator: View {
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

/// Shown on a tab and its project's sidebar row while copilot is waiting on its own
/// background agents. Sized to the reserved 9pt slot so the project name stays aligned.
struct BackgroundAgentsBadge: View {
    var body: some View {
        Image(systemName: "person.2.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 9, height: 9)
            .foregroundStyle(.purple)
            .help("background agents running")
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

// MARK: - Detail (horizontal terminal sessions)

struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // One persistent AppKit container hosts every session's terminal across all
        // projects (see TerminalsContainerView). It's created once and never
        // unmounted, so switching projects or tabs is just a z-order change — SwiftUI
        // never remounts the terminal NSViews, which is what caused the
        // repaint-on-reveal flashes the old opacity/zIndex ZStack couldn't fully fix.
        // Empty / no-project states are drawn by the container's own cover view.
        // activeSessionId + hostedIds are passed so SwiftUI re-runs updateNSView when
        // the selection or the set of sessions changes.
        TerminalsContainer(
            model: model,
            activeSessionId: model.globalSelectedSessionId,
            hostedIds: model.hostedTerminals.map(\.id)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SessionTabBar: View {
    @ObservedObject var model: AppModel
    let project: Project
    @State private var draggedSession: Session?
    @State private var dropTargetId: String?     // a session id, or "" for end-of-row

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(project.sessions.enumerated()), id: \.element.id) { index, session in
                        SessionTab(
                            session: session,
                            isActive: session.id == project.selectedSessionId,
                            number: index < 9 ? index + 1 : nil,
                            showNumber: model.numberHint == .tabs,
                            onSelect: { model.selectSession(projectId: project.id, sessionId: session.id) },
                            onClose: { model.requestCloseSession(projectId: project.id, sessionId: session.id) }
                        )
                        .overlay(alignment: .leading) {
                            insertionBar.opacity(dropTargetId == session.id ? 1 : 0).offset(x: -4)
                        }
                        .onDrag {
                            draggedSession = session
                            dropTargetId = nil
                            return NSItemProvider(object: session.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: TabDropDelegate(
                            targetId: session.id, dragged: $draggedSession,
                            dropTargetId: $dropTargetId, model: model, projectId: project.id))
                    }
                    // Trailing drop zone → move to the end of the row.
                    Color.clear
                        .frame(width: 24)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .leading) {
                            insertionBar.opacity(dropTargetId == "" ? 1 : 0)
                        }
                        .onDrop(of: [.text], delegate: TabDropDelegate(
                            targetId: "", dragged: $draggedSession,
                            dropTargetId: $dropTargetId, model: model, projectId: project.id))
                }
                .padding(.leading, 8)
                .padding(.vertical, 5)
            }
            .frame(maxWidth: .infinity)

            Button { model.addSession(toProjectId: project.id) } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .hoverHighlight()
            .help("New Session (⌘T)")
            .padding(.trailing, 8)
        }
    }

    private var insertionBar: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(width: 3)
            .padding(.vertical, 3)
    }
}

private struct HoverHighlightModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlightModifier())
    }
}

/// Drag-to-reorder for session tabs with an insertion indicator. `targetId` is a
/// session id (insert before it) or "" (move to the end).
private struct TabDropDelegate: DropDelegate {
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

struct SessionTab: View {
    let session: Session
    let isActive: Bool
    var number: Int? = nil
    var showNumber: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                SessionTabIndicator(session: session)
                    .opacity(showNumber ? 0 : 1)
                if showNumber, let number {
                    NumberBadge(number: number)
                }
            }
            .frame(width: 18, height: 18)
            Text(session.title)
                .font(.callout)
                .lineLimit(1)
                .help(session.statusText ?? session.title)
            if session.hasBackgroundWork {
                BackgroundAgentsBadge()
            } else if !session.schedules.isEmpty {
                ScheduleBadge(schedules: session.schedules)
            }
            if session.hasUnread {
                Circle().fill(Color.blue).frame(width: 6, height: 6)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .opacity(0.6)
            .help("Close Session")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 210)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive
                      ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isActive ? Color.accentColor.opacity(0.55) : Color.gray.opacity(0.15),
                        lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
