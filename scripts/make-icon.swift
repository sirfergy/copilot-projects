import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the Copilot Projects app icon to a 1024x1024 PNG: the official GitHub
// Copilot mascot (primer/octicons `copilot-48`, MIT) in white on a teal
// squircle. The octicon path data is embedded and rasterized by the small
// SVG-path parser below, then composited; no external tools required.
// Usage: swift make-icon.swift <out.png> [--opaque]


// Minimal SVG path-data -> CGPath (supports M m L l H h V v C c S s Q q T t A a Z z).
struct PathScanner {
    let s: [Character]; var i = 0
    init(_ str: String) { s = Array(str) }
    mutating func skipSep() { while i < s.count, " ,\n\t\r".contains(s[i]) { i += 1 } }
    mutating func peekCmd() -> Character? { skipSep(); guard i < s.count else { return nil }; return s[i].isLetter ? s[i] : nil }
    mutating func readCmd() -> Character { skipSep(); let c = s[i]; i += 1; return c }
    mutating func readNumber() -> Double {
        skipSep(); var str = ""
        if i < s.count, (s[i] == "+" || s[i] == "-") { str.append(s[i]); i += 1 }
        var dot = false
        while i < s.count {
            let c = s[i]
            if c.isNumber { str.append(c); i += 1 }
            else if c == "." { if dot { break }; dot = true; str.append(c); i += 1 }
            else if c == "e" || c == "E" { str.append(c); i += 1; if i < s.count, (s[i] == "+" || s[i] == "-") { str.append(s[i]); i += 1 } }
            else { break }
        }
        return Double(str) ?? 0
    }
    mutating func readFlag() -> Bool { skipSep(); let c = s[i]; i += 1; return c == "1" }
    mutating func hasNum() -> Bool { skipSep(); guard i < s.count else { return false }; let c = s[i]; return c.isNumber || c == "." || c == "+" || c == "-" }
}

func arcTo(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: Double, ry ry0: Double, phiDeg: Double, large: Bool, sweep: Bool) {
    var rx = abs(rx0), ry = abs(ry0)
    if rx == 0 || ry == 0 { path.addLine(to: p1); return }
    let phi = phiDeg * .pi / 180, cosP = cos(phi), sinP = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1 =  cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
    let lam = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if lam > 1 { let sc = sqrt(lam); rx *= sc; ry *= sc }
    let sign: Double = (large != sweep) ? 1 : -1
    var num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1; if num < 0 { num = 0 }
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    let co = sign * sqrt(num / den)
    let cxp = co * (rx * y1 / ry), cyp = co * (-ry * x1 / rx)
    let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
    let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
    func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let dot = ux * vx + uy * vy, len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
        var a = acos(max(-1, min(1, dot / len))); if ux * vy - uy * vx < 0 { a = -a }; return a
    }
    let t1 = ang(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
    var dt = ang((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
    if !sweep && dt > 0 { dt -= 2 * .pi }
    if sweep && dt < 0 { dt += 2 * .pi }
    let segs = max(1, Int(ceil(abs(dt) / (.pi / 2)))), delta = dt / Double(segs)
    let kappa = 4.0 / 3.0 * tan(delta / 4)
    func pt(_ a: Double) -> CGPoint { let ex = rx * cos(a), ey = ry * sin(a); return CGPoint(x: cosP * ex - sinP * ey + cx, y: sinP * ex + cosP * ey + cy) }
    func dv(_ a: Double) -> CGPoint { let ex = -rx * sin(a), ey = ry * cos(a); return CGPoint(x: cosP * ex - sinP * ey, y: sinP * ex + cosP * ey) }
    for k in 0..<segs {
        let a1 = t1 + delta * Double(k), a2 = a1 + delta
        let pS = pt(a1), pE = pt(a2), dS = dv(a1), dE = dv(a2)
        path.addCurve(to: pE, control1: CGPoint(x: pS.x + kappa * dS.x, y: pS.y + kappa * dS.y),
                              control2: CGPoint(x: pE.x - kappa * dE.x, y: pE.y - kappa * dE.y))
    }
}

func parseSVGPath(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var sc = PathScanner(d)
    var cur = CGPoint.zero, start = CGPoint.zero, ctrl = CGPoint.zero
    var cmd: Character = " ", prevCubic = false, prevQuad = false
    while true {
        if sc.peekCmd() != nil { cmd = sc.readCmd() }
        else if !sc.hasNum() { break }
        else if cmd == "M" { cmd = "L" } else if cmd == "m" { cmd = "l" }
        let rel = cmd.isLowercase
        let lc = Character(cmd.lowercased())
        var nowCubic = false, nowQuad = false
        switch lc {
        case "m":
            var x = sc.readNumber(), y = sc.readNumber(); if rel { x += cur.x; y += cur.y }
            cur = CGPoint(x: x, y: y); start = cur; path.move(to: cur)
        case "l":
            var x = sc.readNumber(), y = sc.readNumber(); if rel { x += cur.x; y += cur.y }
            cur = CGPoint(x: x, y: y); path.addLine(to: cur)
        case "h":
            var x = sc.readNumber(); if rel { x += cur.x }; cur.x = x; path.addLine(to: cur)
        case "v":
            var y = sc.readNumber(); if rel { y += cur.y }; cur.y = y; path.addLine(to: cur)
        case "c":
            var x1 = sc.readNumber(), y1 = sc.readNumber(), x2 = sc.readNumber(), y2 = sc.readNumber(), x = sc.readNumber(), y = sc.readNumber()
            if rel { x1 += cur.x; y1 += cur.y; x2 += cur.x; y2 += cur.y; x += cur.x; y += cur.y }
            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            ctrl = CGPoint(x: x2, y: y2); cur = CGPoint(x: x, y: y); nowCubic = true
        case "s":
            var x2 = sc.readNumber(), y2 = sc.readNumber(), x = sc.readNumber(), y = sc.readNumber()
            if rel { x2 += cur.x; y2 += cur.y; x += cur.x; y += cur.y }
            let c1 = prevCubic ? CGPoint(x: 2 * cur.x - ctrl.x, y: 2 * cur.y - ctrl.y) : cur
            path.addCurve(to: CGPoint(x: x, y: y), control1: c1, control2: CGPoint(x: x2, y: y2))
            ctrl = CGPoint(x: x2, y: y2); cur = CGPoint(x: x, y: y); nowCubic = true
        case "q":
            var x1 = sc.readNumber(), y1 = sc.readNumber(), x = sc.readNumber(), y = sc.readNumber()
            if rel { x1 += cur.x; y1 += cur.y; x += cur.x; y += cur.y }
            path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x1, y: y1))
            ctrl = CGPoint(x: x1, y: y1); cur = CGPoint(x: x, y: y); nowQuad = true
        case "t":
            var x = sc.readNumber(), y = sc.readNumber(); if rel { x += cur.x; y += cur.y }
            let c1 = prevQuad ? CGPoint(x: 2 * cur.x - ctrl.x, y: 2 * cur.y - ctrl.y) : cur
            path.addQuadCurve(to: CGPoint(x: x, y: y), control: c1)
            ctrl = c1; cur = CGPoint(x: x, y: y); nowQuad = true
        case "a":
            let rx = sc.readNumber(), ry = sc.readNumber(), rot = sc.readNumber()
            let large = sc.readFlag(), sweep = sc.readFlag()
            var x = sc.readNumber(), y = sc.readNumber(); if rel { x += cur.x; y += cur.y }
            arcTo(path, from: cur, to: CGPoint(x: x, y: y), rx: rx, ry: ry, phiDeg: rot, large: large, sweep: sweep)
            cur = CGPoint(x: x, y: y)
        case "z":
            path.closeSubpath(); cur = start
        default: break
        }
        prevCubic = nowCubic; prevQuad = nowQuad
    }
    return path
}
let copilotBodyPath = "M47.801 34.003c-1.72 2.988-11.706 10.037-23.82 10.037S1.881 36.991.161 34.003a1.309 1.309 0 0 1-.161-.57v-5.615c.012-.17.047-.338.11-.498.744-1.867 2.692-4.58 5.206-5.308.333-.855.826-2.106 1.287-3.029a20.112 20.112 0 0 1-.104-2.171c0-2.659.563-4.992 2.262-6.729.793-.811 1.777-1.433 2.945-1.901C14.502 5.911 18.483 4 23.938 4c5.455 0 9.523 1.911 12.319 4.182 1.167.468 2.151 1.09 2.944 1.901 1.699 1.737 2.263 4.07 2.263 6.729 0 .736-.027 1.465-.105 2.171.461.923.954 2.174 1.288 3.029 2.513.728 4.461 3.441 5.205 5.308.081.205.115.424.115.645v5.318c0 .252-.04.502-.166.72ZM24.325 22.031h-.688a8.52 8.52 0 0 1-.709 1.016c-1.537 1.892-3.833 2.98-7.008 2.98-3.447 0-5.972-.717-7.557-2.514a4.408 4.408 0 0 1-.171-.21l-.195.21v13.155c2.867 1.558 9.02 4.353 15.984 4.353s13.117-2.795 15.984-4.353V23.513l-.195-.21s-.066.091-.171.21c-1.584 1.797-4.11 2.514-7.557 2.514-3.175 0-5.47-1.088-7.008-2.98a8.637 8.637 0 0 1-.709-1.016h-.033.033Zm-1.969-5.864a14.31 14.31 0 0 0 .127-1.785v-.042c-.003-1.537-.339-2.538-.876-3.152-.681-.78-2.09-1.378-5.06-1.057-3.008.326-4.69 1.073-5.643 2.048-.923.944-1.408 2.356-1.408 4.633 0 2.42.348 3.849 1.115 4.719.729.827 2.165 1.499 5.309 1.499 2.417 0 3.799-.786 4.683-1.873.948-1.168 1.482-2.878 1.753-4.99Zm3.25 0c.271 2.112.805 3.822 1.754 4.99.883 1.087 2.265 1.873 4.682 1.873 3.145 0 4.58-.672 5.309-1.499.767-.87 1.116-2.299 1.116-4.719 0-2.277-.485-3.689-1.408-4.633-.954-.975-2.635-1.722-5.644-2.048-2.969-.321-4.378.277-5.06 1.057-.537.614-.873 1.615-.876 3.152v.042c.002.53.042 1.123.127 1.785Z"
let copilotMouthPath = "M28.998 28.516c1.104 0 1.999.895 1.999 1.999v3.998a2 2 0 1 1-3.998 0v-3.998c0-1.104.895-1.999 1.999-1.999Zm-9.996 0c1.104 0 1.999.895 1.999 1.999v3.998a2 2 0 1 1-3.998 0v-3.998c0-1.104.895-1.999 1.999-1.999Z"

// MARK: - Render

let S = 1024.0
let arguments = CommandLine.arguments.dropFirst()
let opaque = arguments.contains("--opaque")
let out = arguments.first { !$0.hasPrefix("--") } ?? "icon-1024.png"
let cs = CGColorSpaceCreateDeviceRGB()
func col(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])!
}
func rrect(_ rect: CGRect, _ radius: Double) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
    space: cs,
    bitmapInfo: (
        opaque
            ? CGImageAlphaInfo.noneSkipLast
            : CGImageAlphaInfo.premultipliedLast
    ).rawValue
) else { exit(1) }
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// teal squircle background
let margin = 70.0
let bg = opaque
    ? CGRect(x: 0, y: 0, width: S, height: S)
    : CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
ctx.saveGState()
ctx.addPath(opaque ? CGPath(rect: bg, transform: nil) : rrect(bg, 208))
ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [col(45, 212, 191), col(13, 148, 136)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: bg.minX, y: bg.maxY),
                       end: CGPoint(x: bg.maxX, y: bg.minY), options: [])
let sheen = CGGradient(colorsSpace: cs,
                       colors: [col(255, 255, 255, 0.16), col(255, 255, 255, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: bg.midX, y: bg.maxY),
                       end: CGPoint(x: bg.midX, y: bg.midY), options: [])
ctx.restoreGState()

// Copilot octicon: scale its 48x48 viewBox into a centered box, flipping y
// (SVG is y-down, CoreGraphics is y-up). Eyes + mouth are even-odd knockouts.
let target = 660.0
let scale = target / 48.0
let ox = (S - target) / 2.0
let oy = (S - target) / 2.0
var xform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: ox, ty: oy + 48 * scale)
let mark = CGMutablePath()
mark.addPath(parseSVGPath(copilotBodyPath))
mark.addPath(parseSVGPath(copilotMouthPath))
let placed = mark.copy(using: &xform)!

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 38, color: col(4, 47, 46, 0.5))
ctx.addPath(placed)
ctx.setFillColor(col(255, 255, 255))
ctx.fillPath(using: .evenOdd)
ctx.restoreGState()

guard let image = ctx.makeImage() else { exit(1) }
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
    UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
