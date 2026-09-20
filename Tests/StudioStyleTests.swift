import AppKit
import SwiftUI
import XCTest
@testable import CopilotProjectsHost

final class StudioStyleTests: XCTestCase {
    @MainActor
    func testSelectionAndLabelsHaveContrastInEveryAppearance() throws {
        for name: NSAppearance.Name in [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for surface in [StudioStyle.chrome, StudioStyle.sidebar, StudioStyle.raised,
                                StudioStyle.selection, StudioStyle.message] {
                    let background = NSColor(surface).usingColorSpace(.sRGB)!
                    let label = NSColor.labelColor.usingColorSpace(.sRGB)!
                    XCTAssertGreaterThanOrEqual(contrast(label, background), 4.5, name.rawValue)
                    let secondary = NSColor(StudioStyle.secondaryText).usingColorSpace(.sRGB)!
                    XCTAssertGreaterThanOrEqual(contrast(secondary, background), 4.5, name.rawValue)
                }
                let edge = NSColor(StudioStyle.selectionEdge).usingColorSpace(.sRGB)!
                let selected = NSColor(StudioStyle.selection).usingColorSpace(.sRGB)!
                XCTAssertGreaterThanOrEqual(contrast(edge, selected), 3, name.rawValue)
                let raised = NSColor(StudioStyle.raised).usingColorSpace(.sRGB)!
                for surface in [StudioStyle.chrome, StudioStyle.sidebar] {
                    let background = NSColor(surface).usingColorSpace(.sRGB)!
                    XCTAssertGreaterThanOrEqual(contrast(raised, background), 1.1, name.rawValue)
                }
            }
        }
    }

    private func contrast(_ foreground: NSColor, _ background: NSColor) -> Double {
        let back = [background.redComponent, background.greenComponent, background.blueComponent]
        let front = [foreground.redComponent, foreground.greenComponent, foreground.blueComponent]
        let composite = zip(front, back).map { $0 * foreground.alphaComponent + $1 * (1 - foreground.alphaComponent) }
        func luminance(_ components: [CGFloat]) -> Double {
            let linear = components.map { value in
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let values = [luminance(composite), luminance(back)]
        return (values.max()! + 0.05) / (values.min()! + 0.05)
    }
}
