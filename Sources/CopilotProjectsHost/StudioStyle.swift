import AppKit
import SwiftUI

enum StudioStyle {
    static let chrome = color(0xF0F2F4, 0x202327, highLight: 0xFFFFFF, highDark: 0x000000)
    static let sidebar = color(0xE4E8EC, 0x25292E, highLight: 0xDCE1E6, highDark: 0x16191D)
    static let raised = color(0xFFFFFF, 0x30363D, highLight: 0xEDF1F5, highDark: 0x24292F)
    static let selection = color(0xD4E0EB, 0x3C4A56, highLight: 0xCCDDE9, highDark: 0x374A59)
    static let selectionEdge = color(0x365A76, 0xAAC6D9, highLight: 0x173B55, highDark: 0xD5E9F6)
    static let message = color(0xE5EDF3, 0x2D3943, highLight: 0xE2EAF0, highDark: 0x283742)
    static let secondaryText = color(0x526170, 0xBAC4CE, highLight: 0x394958, highDark: 0xD5E0E9)

    private static func color(
        _ light: UInt32, _ dark: UInt32, highLight: UInt32, highDark: UInt32
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value: UInt32
            switch appearance.bestMatch(from: [
                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                .aqua, .darkAqua,
            ]) {
            case .accessibilityHighContrastAqua: value = highLight
            case .accessibilityHighContrastDarkAqua: value = highDark
            case .darkAqua: value = dark
            default: value = light
            }
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
