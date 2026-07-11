import SwiftUI
import WebKit

struct CloudflareLoginView: UIViewRepresentable {
    let session: CloudflareSession
    let onAuthenticated: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onAuthenticated: onAuthenticated)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: CloudflareSession.origin))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let session: CloudflareSession
        let onAuthenticated: () -> Void

        init(session: CloudflareSession, onAuthenticated: @escaping () -> Void) {
            self.session = session
            self.onAuthenticated = onAuthenticated
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            Task { @MainActor in
                for _ in 0 ..< 10 {
                    await session.refreshFromWebKit()
                    if session.isAuthenticated {
                        onAuthenticated()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }
}
