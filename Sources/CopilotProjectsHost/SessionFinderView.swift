import SwiftUI
import AppKit
import CopilotProjectsCore
import CopilotProjectsProtocol

/// State for one presentation of the session finder. Name, project, folder, and
/// conversation matches are instant; Luna adds meaning-based picks after the
/// user pauses typing.
@MainActor
final class SessionFinderModel: ObservableObject, Identifiable {
    enum LunaPhase: Equatable {
        case idle
        /// Waiting for the user to pause before asking.
        case pending
        case searching
        case finished([LunaMatch])
        case failed(String)
    }

    enum Section: Hashable {
        case recent, matches, luna

        var title: String {
            switch self {
            case .recent: return "Recent Sessions"
            case .matches: return "Matches"
            case .luna: return "Suggested by Luna"
            }
        }
    }

    struct Row: Identifiable {
        let entry: SessionFinderEntry
        let section: Section
        /// The conversation excerpt that matched, when the name, project, and folder did not.
        let snippet: String?
        /// Why Luna picked this session, if it did.
        let lunaReason: String?
        var id: String { entry.id }
    }

    /// What VoiceOver hears about the highlighted row.
    struct Highlight: Equatable {
        let sessionId: String?
        let lunaReason: String?

        /// A new row is always worth hearing; the same row only when Luna adds or
        /// changes its reason, not when a reason drops away mid-typing.
        func isWorthAnnouncing(after previous: Highlight) -> Bool {
            sessionId != previous.sessionId || (lunaReason != nil && lunaReason != previous.lunaReason)
        }
    }

    static let minimumLunaQueryLength = 3

    nonisolated let id = UUID()
    @Published var query = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var luna: LunaPhase = .idle
    @Published private(set) var highlightedId: String?
    @Published private(set) var isIndexing = true

    var highlight: Highlight {
        Highlight(sessionId: highlightedId, lunaReason: rows.first { $0.id == highlightedId }?.lunaReason)
    }

    /// Luna's picks that are still listed. Picks for sessions that ended since are
    /// left out, including ones from a cached or late answer.
    var lunaSuggestionCount: Int {
        rows.reduce(0) { $0 + ($1.lunaReason == nil ? 0 : 1) }
    }

    private(set) var entries: [SessionFinderEntry]
    private var liveSessionIds: Set<String>
    private var localMatches: [SessionFinderSearch.LocalMatch] = []
    private var lunaCache: [String: [LunaMatch]] = [:]
    private var indexTask: Task<Void, Never>?
    private var lunaTask: Task<Void, Never>?
    private var userMovedHighlight = false
    private let currentSessionId: String?
    private let ranker: SessionRanking
    private let lunaDelay: TimeInterval
    private let onOpen: (String) -> Void

    init(
        sources: [SessionFinderSource],
        currentSessionId: String? = nil,
        ranker: SessionRanking = LunaSessionRanker(),
        lunaDelay: TimeInterval = 0.6,
        loadTranscript: @escaping @Sendable (String) -> TranscriptSnapshot? = {
            TranscriptController.loadRemoteSnapshot(sessionId: $0)
        },
        onOpen: @escaping (String) -> Void
    ) {
        self.currentSessionId = currentSessionId
        self.ranker = ranker
        self.lunaDelay = lunaDelay
        self.onOpen = onOpen
        entries = sources.map { SessionFinderEntry(source: $0) }
        liveSessionIds = Set(sources.map(\.sessionId))
        rebuildRows()
        indexTask = Task { [weak self] in
            let scan = Task.detached(priority: .userInitiated) {
                SessionFinderSearch.index(sources, loadTranscript: loadTranscript)
            }
            let indexed = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.entries = indexed
            self.isIndexing = false
            self.refreshLocalMatches()
            self.scheduleLuna()
        }
    }

    /// Stops indexing and any Luna run. Call when the finder closes.
    func cancel() {
        indexTask?.cancel()
        lunaTask?.cancel()
        indexTask = nil
        lunaTask = nil
    }

    /// Drops sessions that ended while the finder was open.
    func retainSessions(_ sessionIds: Set<String>) {
        guard sessionIds != liveSessionIds else { return }
        liveSessionIds = sessionIds
        rebuildRows()
    }

    func moveHighlight(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == highlightedId } ?? (delta > 0 ? -1 : rows.count)
        let next = min(max(current + delta, 0), rows.count - 1)
        highlightedId = rows[next].id
        userMovedHighlight = true
    }

    func openHighlighted() {
        guard let sessionId = highlightedId ?? rows.first?.id else { return }
        onOpen(sessionId)
    }

    func open(_ sessionId: String) {
        onOpen(sessionId)
    }

    private func queryDidChange() {
        userMovedHighlight = false
        lunaTask?.cancel()
        lunaTask = nil
        refreshLocalMatches()
        scheduleLuna()
    }

    private func refreshLocalMatches() {
        localMatches = SessionFinderSearch.localMatches(for: query, in: entries)
        rebuildRows()
    }

    private func scheduleLuna() {
        let text = SessionFinderSearch.collapseWhitespace(query)
        guard !isIndexing, text.count >= Self.minimumLunaQueryLength, !entries.isEmpty else {
            luna = .idle
            rebuildRows()
            return
        }
        let key = SessionFinderSearch.fold(text)
        if let cached = lunaCache[key] {
            luna = .finished(cached)
            rebuildRows()
            return
        }
        luna = .pending
        rebuildRows()
        let entries = entries
        let ranker = ranker
        let delay = lunaDelay
        lunaTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.luna = .searching
            let phase: LunaPhase
            do {
                let matches = try await ranker.rank(query: text, entries: entries)
                guard !Task.isCancelled else { return }
                self?.lunaCache[key] = matches
                phase = .finished(matches)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                phase = .failed((error as? LunaSearchError)?.message ?? error.localizedDescription)
            }
            self?.luna = phase
            self?.rebuildRows()
        }
    }

    private func rebuildRows() {
        let live = entries.filter { liveSessionIds.contains($0.id) }
        var built: [Row]
        let browsing = SessionFinderSearch.tokens(query).isEmpty
        if browsing {
            built = SessionFinderSearch.recent(live).map {
                Row(entry: $0, section: .recent, snippet: nil, lunaReason: nil)
            }
        } else {
            var picks: [LunaMatch] = []
            if case .finished(let matches) = luna { picks = matches }
            let reasons = Dictionary(picks.map { ($0.sessionId, $0.reason) }, uniquingKeysWith: { first, _ in first })
            built = localMatches.filter { liveSessionIds.contains($0.entry.id) }.map { match in
                Row(
                    entry: match.entry, section: .matches,
                    snippet: match.snippet, lunaReason: reasons[match.entry.id]
                )
            }
            // Luna's extra picks go below the instant matches so a late answer never
            // moves the row under the cursor.
            let listed = Set(built.map(\.id))
            let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for pick in picks where !listed.contains(pick.sessionId) {
                guard let entry = byId[pick.sessionId] else { continue }
                built.append(Row(entry: entry, section: .luna, snippet: nil, lunaReason: pick.reason))
            }
        }
        rows = built
        if !(userMovedHighlight && built.contains { $0.id == highlightedId }) {
            // Browsing defaults past the current session, like ⌘Tab.
            let preferred = browsing ? built.first { $0.id != currentSessionId } : nil
            highlightedId = (preferred ?? built.first)?.id
            userMovedHighlight = false
        }
    }
}

extension AppModel {
    var sessionFinderSources: [SessionFinderSource] {
        projects.flatMap { project in
            project.sessions.map {
                SessionFinderSource(
                    sessionId: $0.id, projectId: project.id, projectName: project.name,
                    title: $0.title, cwd: $0.cwd,
                    lastActivity: (try? FileManager.default.attributesOfItem(
                        atPath: Paths.transcriptSnapshotPath(sessionId: $0.id)
                    ))?[.modificationDate] as? Date
                )
            }
        }
    }
}

struct SessionFinderView: View {
    @ObservedObject var finder: SessionFinderModel
    @ObservedObject var model: AppModel
    let onDismiss: () -> Void
    @FocusState private var searchFocused: Bool

    private struct LiveSession {
        let session: Session
        let projectName: String
    }

    var body: some View {
        let live = liveSessions
        VStack(spacing: 0) {
            searchField
            Divider()
            results(live: live)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 640, height: 460)
        .background(StudioStyle.chrome)
        .defaultFocus($searchFocused, true)
        .onAppear {
            searchFocused = true
            announce(finder.highlightedId, live: live)
        }
        .onDisappear { finder.cancel() }
        .onChange(of: liveSessionIds) { _, ids in finder.retainSessions(Set(ids)) }
        .onChange(of: finder.highlight) { previous, highlight in
            if highlight.isWorthAnnouncing(after: previous) { announce(highlight.sessionId, live: live) }
        }
    }

    private var liveSessionIds: [String] {
        model.projects.flatMap { $0.sessions.map(\.id) }
    }

    private var liveSessions: [String: LiveSession] {
        var sessions: [String: LiveSession] = [:]
        for project in model.projects {
            for session in project.sessions {
                sessions[session.id] = LiveSession(session: session, projectName: project.name)
            }
        }
        return sessions
    }

    /// Focus stays in the search field, so VoiceOver hears the highlighted row.
    private func announce(_ sessionId: String?, live: [String: LiveSession]) {
        guard let sessionId, let current = live[sessionId],
              let row = finder.rows.first(where: { $0.id == sessionId }) else { return }
        var text = "\(current.session.title), \(current.projectName), \(current.session.attentionLabel)"
        if let reason = row.lunaReason, !reason.isEmpty { text += ". Suggested by Luna: \(reason)" }
        AccessibilityNotification.Announcement(text).post()
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(StudioStyle.secondaryText)
                .accessibilityHidden(true)
            TextField(
                "Find Session",
                text: $finder.query,
                prompt: Text("Session name, project, folder, or what you worked on")
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($searchFocused)
            .accessibilityIdentifier("session-finder-field")
            if finder.luna == .searching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Asking Luna")
                }
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    @ViewBuilder
    private func results(live: [String: LiveSession]) -> some View {
        let rows = finder.rows
        let searching = !SessionFinderSearch.tokens(finder.query).isEmpty
        if live.isEmpty {
            ContentUnavailableView(
                "No Sessions Yet", systemImage: "terminal",
                description: Text("Start a Copilot session with ⌘T, then find it here.")
            )
        } else if rows.isEmpty && searching && finder.isIndexing {
            statusList(title: SessionFinderModel.Section.matches.title, message: "Reading conversations…")
        } else if rows.isEmpty && finder.luna == .pending {
            statusList(title: SessionFinderModel.Section.luna.title, message: "Luna searches when you pause typing.")
        } else if rows.isEmpty && finder.luna == .searching {
            statusList(title: SessionFinderModel.Section.luna.title, message: "Luna is looking through your conversations…")
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: finder.query)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections(rows), id: \.section) { group in
                            sectionHeader(group.section.title)
                            ForEach(group.rows) { row in
                                if let current = live[row.id] {
                                    SessionFinderRow(
                                        row: row,
                                        session: current.session,
                                        projectName: current.projectName,
                                        isHighlighted: row.id == finder.highlightedId,
                                        isCurrent: row.id == model.globalSelectedSessionId,
                                        onOpen: { finder.open(row.id) }
                                    )
                                    .id(row.id)
                                }
                            }
                        }
                        if finder.luna == .searching && !rows.contains(where: { $0.section == .luna }) {
                            sectionHeader(SessionFinderModel.Section.luna.title)
                            statusText("Luna is looking through your conversations…")
                        }
                    }
                    .padding(8)
                }
                .onChange(of: finder.highlightedId) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private func statusList(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(title)
            statusText(message)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(StudioStyle.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
    }

    private func sections(_ rows: [SessionFinderModel.Row]) -> [(section: SessionFinderModel.Section, rows: [SessionFinderModel.Row])] {
        var groups: [(section: SessionFinderModel.Section, rows: [SessionFinderModel.Row])] = []
        for row in rows {
            if groups.last?.section == row.section {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append((row.section, [row]))
            }
        }
        return groups
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudioStyle.secondaryText)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            keyHint("↑↓", "Move")
            keyHint("↩", "Open")
            // Escape clears a search before it closes; the legend says which.
            Button {
                if finder.query.isEmpty { onDismiss() } else { finder.query = "" }
            } label: {
                keyHint("esc", finder.query.isEmpty ? "Close" : "Clear")
            }
            .buttonStyle(.plain)
            .help(finder.query.isEmpty ? "Close Find Session" : "Clear the search")
            Spacer(minLength: 12)
            lunaNote
        }
        .font(.caption)
        .foregroundStyle(StudioStyle.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(StudioStyle.sidebar)
    }

    @ViewBuilder
    private var lunaNote: some View {
        switch finder.luna {
        case .idle, .pending:
            Text("Luna joins when you pause typing")
                .lineLimit(1)
                .help("Meaning-based suggestions use \(LunaSessionRanker.model) through the Copilot CLI, with no tools.")
        case .searching:
            EmptyView()
        case .finished:
            let count = finder.lunaSuggestionCount
            Text(count == 0
                 ? "Luna found nothing more"
                 : "Luna suggested \(count) \(count == 1 ? "session" : "sessions")")
                .lineLimit(1)
        case .failed(let message):
            Label {
                Text(message).lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .help(message)
        }
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
            Text(action)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SessionFinderRow: View {
    let row: SessionFinderModel.Row
    let session: Session
    let projectName: String
    let isHighlighted: Bool
    let isCurrent: Bool
    let onOpen: () -> Void
    @State private var isHovering = false

    private var context: String {
        var parts = [projectName]
        let folder = row.entry.folderName
        if !folder.isEmpty, folder != "/", folder != projectName { parts.append(folder) }
        parts.append(session.attentionLabel)
        if isCurrent { parts.append("Current") }
        return parts.joined(separator: " · ")
    }

    private var reason: String? {
        guard let reason = row.lunaReason, !reason.isEmpty else { return nil }
        return reason
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            SessionStateIndicator(session: session)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let lastActivity = row.entry.lastActivity {
                        Text(lastActivity, format: .relative(presentation: .named))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(StudioStyle.secondaryText)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // A pick on an already-listed row stays inline so the list never shifts.
                    if row.section != .luna, row.lunaReason != nil {
                        lunaMark
                    }
                    Text(context)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
                if row.section == .luna, let reason {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        lunaMark
                        Text(reason).foregroundStyle(Color.primary).lineLimit(1)
                    }
                    .font(.caption)
                } else if let snippet = row.snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(StudioStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? StudioStyle.selection : isHovering ? StudioStyle.raised : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isHighlighted ? StudioStyle.selectionEdge : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .help(reason.map { "\(session.title)\nSuggested by Luna: \($0)" } ?? session.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onOpen() }
    }

    private var lunaMark: some View {
        Image(systemName: "sparkle")
            .foregroundStyle(StudioStyle.selectionEdge)
            .accessibilityLabel(reason.map { "Suggested by Luna: \($0)." } ?? "Suggested by Luna.")
    }
}
