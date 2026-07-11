import SwiftUI

struct ConnectionIndicator: View {
    let state: RemoteConnectionState

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting, .reconnecting, .authenticating: .orange
        case .disconnected, .error: .red
        }
    }

    private var label: String {
        switch state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .authenticating: "Sign in required"
        case .disconnected: "Disconnected"
        case .error(let message): message
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.35), radius: 2)
            .accessibilityLabel(label)
            .help(label)
    }
}

