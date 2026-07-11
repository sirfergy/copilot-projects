import SwiftUI
import UIKit
import CopilotProjectsProtocol

struct TerminalScreenView: View {
    let client: RemoteClient
    var onShowSessions: (() -> Void)?
    @State private var input = ""
    @State private var lastDragLocation: CGPoint?
    @State private var horizontalOffset: CGFloat = 0
    @State private var dragStartOffset: CGFloat?
    @FocusState private var inputFocused: Bool

    private var displayedLines: [TerminalLine] {
        if client.terminal.mode == .terminal {
            return Array(client.terminal.lines.suffix(55))
        }
        return client.terminal.lines
    }

    private var terminalContentWidth: CGFloat {
        let longestLine = displayedLines.map(\.text.count).max() ?? 0
        let columns = max(client.terminal.cols, longestLine, 40)
        let font = UIFont.monospacedSystemFont(
            ofSize: 10,
            weight: .regular
        )
        let cellWidth = ("M" as NSString).size(
            withAttributes: [.font: font]
        ).width
        return CGFloat(columns) * cellWidth + 16
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let onShowSessions {
                    Button(action: onShowSessions) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Sessions")
                }
                ForEach([
                    ("Esc", "escape"),
                    ("⌃C", "control-c"),
                    ("Tab", "tab"),
                    ("↑", "up"),
                    ("↓", "down"),
                ], id: \.0) { key in
                    Button(key.0) { sendSpecial(key.1) }
                        .buttonStyle(.bordered)
                        .disabled(!client.writable)
                }
                Spacer()
            }
            .padding(8)

            if client.terminal.mode == .terminal {
                GeometryReader { geometry in
                    terminalRows
                        .frame(
                            width: terminalContentWidth,
                            height: geometry.size.height,
                            alignment: .topLeading
                        )
                        .offset(x: horizontalOffset)
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged {
                                    handleTerminalDrag(
                                        $0,
                                        viewportWidth: geometry.size.width
                                    )
                                }
                                .onEnded { _ in
                                    lastDragLocation = nil
                                    dragStartOffset = nil
                                }
                        )
                        .onTapGesture { inputFocused.toggle() }
                }
                .clipped()
            } else {
                ScrollView([.horizontal, .vertical]) {
                    terminalRows
                        .frame(
                            minWidth: terminalContentWidth,
                            alignment: .leading
                        )
                }
                .defaultScrollAnchor(.bottom)
                .onTapGesture { inputFocused.toggle() }
            }

            HStack {
                TextField("Send a command", text: $input)
                    .focused($inputFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .foregroundStyle(.primary)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                Button("Send", action: send)
                    .disabled(input.isEmpty || !client.writable)
            }
            .padding(8)
            .background(.bar)
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .background(HardwareKeyCommands(send: sendSpecial))
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { inputFocused = false }
            }
        }
    }

    private func send() {
        guard !input.isEmpty else { return }
        client.sendCommand(input)
        input = ""
    }

    private func sendSpecial(_ key: String) {
        if key == "enter", !input.isEmpty {
            client.sendCommand(input)
            input = ""
            return
        }
        if key == "control-c" {
            input = ""
            client.sendInput("\u{3}")
        } else {
            if !input.isEmpty {
                client.sendInput(input)
                input = ""
            }
            client.sendKey(key)
        }
    }

    private var terminalRows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(displayedLines) { line in
                TerminalLineView(text: line.text)
            }
        }
        .padding(8)
    }

    private func handleTerminalDrag(
        _ value: DragGesture.Value,
        viewportWidth: CGFloat
    ) {
        let maximumOffset = max(0, terminalContentWidth - viewportWidth)
        if abs(value.translation.width) > abs(value.translation.height) {
            if dragStartOffset == nil {
                dragStartOffset = horizontalOffset - value.translation.width
            }
            horizontalOffset = min(
                0,
                max(
                    -maximumOffset,
                    (dragStartOffset ?? 0) + value.translation.width
                )
            )
            lastDragLocation = value.location
            return
        }
        dragStartOffset = nil
        if let lastDragLocation {
            let dy = value.location.y - lastDragLocation.y
            let chunks = Int(abs(dy) / 18)
            if chunks > 0 {
                client.sendScroll(dy > 0 ? 2 * chunks : -2 * chunks)
                let direction: CGFloat = dy > 0 ? 1 : -1
                let consumed = CGFloat(chunks * 18) * direction
                self.lastDragLocation = CGPoint(
                    x: lastDragLocation.x,
                    y: lastDragLocation.y + consumed
                )
            }
        } else {
            lastDragLocation = value.location
        }
    }
}
