import SwiftUI
import UIKit

struct TerminalLineView: View {
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    let text: String

    var body: some View {
        Text(linkified(text))
            .font(.system(size: 10, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func linkified(_ value: String) -> AttributedString {
        let attributed = NSMutableAttributedString(string: value)
        guard let detector = Self.linkDetector else {
            return AttributedString(attributed)
        }
        let range = NSRange(location: 0, length: (value as NSString).length)
        detector.enumerateMatches(in: value, range: range) { match, _, _ in
            guard let match, let url = match.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return
            }
            attributed.addAttribute(.link, value: url, range: match.range)
            attributed.addAttribute(
                .foregroundColor,
                value: UIColor.systemBlue,
                range: match.range
            )
        }
        return AttributedString(attributed)
    }
}
