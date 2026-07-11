import SwiftUI
import UIKit

struct HardwareKeyCommands: UIViewControllerRepresentable {
    let send: (String) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(send: send)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.send = send
    }

    final class Controller: UIViewController {
        var send: (String) -> Void

        init(send: @escaping (String) -> Void) {
            self.send = send
            super.init(nibName: nil, bundle: nil)
            view.isHidden = true
        }

        required init?(coder: NSCoder) { nil }

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            [
                command(UIKeyCommand.inputEscape),
                command(UIKeyCommand.inputUpArrow),
                command(UIKeyCommand.inputDownArrow),
                command(UIKeyCommand.inputLeftArrow),
                command(UIKeyCommand.inputRightArrow),
                UIKeyCommand(
                    input: "c",
                    modifierFlags: .control,
                    action: #selector(controlC)
                ),
            ]
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }

        private func command(_ input: String) -> UIKeyCommand {
            UIKeyCommand(
                input: input,
                modifierFlags: [],
                action: #selector(specialKey(_:))
            )
        }

        @objc private func specialKey(_ sender: UIKeyCommand) {
            switch sender.input {
            case UIKeyCommand.inputEscape: send("escape")
            case UIKeyCommand.inputUpArrow: send("up")
            case UIKeyCommand.inputDownArrow: send("down")
            case UIKeyCommand.inputLeftArrow: send("left")
            case UIKeyCommand.inputRightArrow: send("right")
            default: break
            }
        }

        @objc private func controlC() { send("control-c") }
    }
}
