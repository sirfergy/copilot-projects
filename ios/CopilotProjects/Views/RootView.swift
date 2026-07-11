import SwiftUI
import CopilotProjectsProtocol

private struct SessionRoute: Hashable {
    let projectID: String
    let sessionID: String
    let title: String
}

struct RootView: View {
    let authentication: CloudflareSession
    let client: RemoteClient
    let notifications: NotificationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var path: [SessionRoute] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactNavigation
            } else {
                splitNavigation
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { authentication.needsLogin },
            set: { authentication.needsLogin = $0 }
        )) {
            NavigationStack {
                CloudflareLoginView(session: authentication) {
                    authentication.needsLogin = false
                    client.setActive(true)
                }
                .navigationTitle("Sign in")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            client.setActive(phase == .active)
            if phase == .active {
                notifications.resumeRegistrationIfAuthorized()
            }
        }
        .onChange(of: notifications.deviceToken) { _, token in
            guard let token else { return }
            Task {
                try? await client.registerAPNs(
                    token: token,
                    environment: notifications.environment
                )
            }
        }
        .onChange(
            of: notifications.pendingDeepLink,
            initial: true
        ) { _, deepLink in
            guard let deepLink else { return }
            follow(deepLink)
            notifications.pendingDeepLink = nil
        }
        .onChange(of: client.selectedSessionID) { _, sessionID in
            guard horizontalSizeClass == .compact,
                  let sessionID,
                  let route = route(for: sessionID),
                  path.last != route else {
                return
            }
            path = [route]
        }
        .onOpenURL { url in
            if let deepLink = AppDeepLink(url: url) {
                follow(deepLink)
            }
        }
    }

    private var compactNavigation: some View {
        NavigationStack(path: $path) {
            compactSessionList
                .navigationDestination(for: SessionRoute.self) { route in
                    TerminalScreenView(
                        client: client,
                        onShowSessions: {
                            if !path.isEmpty { path.removeLast() }
                        }
                    )
                        .toolbar(.hidden, for: .navigationBar)
                        .onAppear {
                            client.select(
                                projectID: route.projectID,
                                sessionID: route.sessionID
                            )
                        }
                }
        }
    }

    private func follow(_ deepLink: AppDeepLink) {
        client.follow(deepLink)
        guard horizontalSizeClass == .compact,
              let sessionID = deepLink.sessionId,
              let route = route(for: sessionID) else {
            return
        }
        path = [route]
    }

    private var compactSessionList: some View {
        List {
            ForEach(client.workspace?.projects ?? [], id: \.id) { project in
                Section(project.name) {
                    ForEach(project.sessions, id: \.id) { session in
                        NavigationLink(value: SessionRoute(
                            projectID: project.id,
                            sessionID: session.id,
                            title: session.title
                        )) {
                            sessionLabel(session)
                        }
                    }
                }
            }
        }
        .navigationTitle("Copilot Projects")
        .toolbar { listToolbar }
    }

    private var splitNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                ForEach(client.workspace?.projects ?? [], id: \.id) { project in
                    Section(project.name) {
                        ForEach(project.sessions, id: \.id) { session in
                            Button {
                                client.select(
                                    projectID: project.id,
                                    sessionID: session.id
                                )
                                columnVisibility = .detailOnly
                            } label: {
                                sessionLabel(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Copilot Projects")
            .toolbar { listToolbar }
        } detail: {
            if client.selectedSessionID != nil {
                TerminalScreenView(client: client)
                    .navigationTitle(selectedSessionTitle)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "terminal"
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            ConnectionIndicator(state: client.connectionState)
            Button {
                notifications.requestAuthorization()
            } label: {
                Image(systemName: "bell")
            }
            Button("Sign Out") {
                Task {
                    await authentication.logout()
                    client.setActive(false)
                }
            }
        }
    }

    private func sessionLabel(_ session: RemoteSessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .lineLimit(2)
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor(session.status))
                    .frame(width: 7, height: 7)
                Text(session.status)
                if session.background { Text("background") }
                if session.scheduled { Text("scheduled") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var selectedSessionTitle: String {
        client.workspace?.projects
            .flatMap(\.sessions)
            .first { $0.id == client.selectedSessionID }?
            .title ?? "Terminal"
    }

    private func route(for sessionID: String) -> SessionRoute? {
        for project in client.workspace?.projects ?? [] {
            if let session = project.sessions.first(where: { $0.id == sessionID }) {
                return SessionRoute(
                    projectID: project.id,
                    sessionID: session.id,
                    title: session.title
                )
            }
        }
        return nil
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running": .green
        case "waiting": .orange
        default: .secondary
        }
    }
}
