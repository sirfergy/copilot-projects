import Foundation
import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One item within a Markdown list, preserving its authored marker (so ordered
/// lists keep their real numbers) and indentation depth (so nested items stay
/// nested).
public struct MarkdownListItem: Equatable, Sendable {
    public let marker: String
    public let text: String
    public let depth: Int

    public init(marker: String, text: String, depth: Int) {
        self.marker = marker
        self.text = text
        self.depth = depth
    }
}

/// Per-column alignment for a table, parsed from the colons in the delimiter row.
public enum MarkdownColumnAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

/// A GitHub-flavored table: a header row, per-column alignment, and body rows.
/// Rows are stored as raw cell strings so each cell can still render inline
/// Markdown.
public struct MarkdownTable: Equatable, Sendable {
    public let header: [String]
    public let alignments: [MarkdownColumnAlignment]
    public let rows: [[String]]

    public init(
        header: [String],
        alignments: [MarkdownColumnAlignment],
        rows: [[String]]
    ) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

/// A single block-level element parsed from Markdown.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(String)
    case quote(String)
    case list([MarkdownListItem])
    case table(MarkdownTable)
}

/// Bounded, thread-safe LRU cache keyed by raw Markdown text so repeated view
/// evaluations during streaming or scrolling reuse parsed block structures and
/// inline `AttributedString` values without re-parsing on `@MainActor`.
public final class MarkdownLRUCache<Value: Sendable>: @unchecked Sendable {
    private final class Node {
        let key: String
        var value: Value
        var cost: Int
        weak var prev: Node?
        var next: Node?

        init(key: String, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    public let maxEntries: Int
    public let maxCostBytes: Int
    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private var totalCostBytes = 0
    private var hits = 0
    private var misses = 0

    public init(maxEntries: Int, maxCostBytes: Int = 4 * 1_024 * 1_024) {
        self.maxEntries = max(1, maxEntries)
        self.maxCostBytes = max(1, maxCostBytes)
    }

    public func value(for key: String, compute: (String) -> Value) -> Value {
        lock.lock()
        if let existing = nodes[key] {
            moveToHead(existing)
            hits += 1
            let cached = existing.value
            lock.unlock()
            return cached
        }
        misses += 1
        lock.unlock()

        let computed = compute(key)
        let cost = max(1, key.utf8.count)
        guard cost <= maxCostBytes else {
            return computed
        }

        lock.lock()
        defer { lock.unlock() }
        if let raced = nodes[key] {
            totalCostBytes += cost - raced.cost
            raced.value = computed
            raced.cost = cost
            moveToHead(raced)
            evictIfNeeded()
            return computed
        }
        let node = Node(key: key, value: computed, cost: cost)
        nodes[key] = node
        insertAtHead(node)
        totalCostBytes += cost
        evictIfNeeded()
        return computed
    }

    public func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nodes[key] != nil
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return nodes.count
    }

    public var totalCost: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCostBytes
    }

    public var stats: (hits: Int, misses: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hits, misses)
    }

    public func removeAll() {
        lock.lock()
        var current = head
        while let node = current {
            let next = node.next
            node.prev = nil
            node.next = nil
            current = next
        }
        nodes.removeAll()
        head = nil
        tail = nil
        totalCostBytes = 0
        hits = 0
        misses = 0
        lock.unlock()
    }

    private func insertAtHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil {
            tail = node
        }
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        detach(node)
        insertAtHead(node)
    }

    private func detach(_ node: Node) {
        let prev = node.prev
        let next = node.next
        if let prev {
            prev.next = next
        } else {
            head = next
        }
        if let next {
            next.prev = prev
        } else {
            tail = prev
        }
        node.prev = nil
        node.next = nil
    }

    private func evictIfNeeded() {
        while (nodes.count > maxEntries || totalCostBytes > maxCostBytes),
              let oldest = tail {
            detach(oldest)
            nodes.removeValue(forKey: oldest.key)
            totalCostBytes -= oldest.cost
        }
    }
}

/// Splits Markdown into block-level elements. Kept dependency-free and pure so
/// it can be unit tested without a view host.
public enum MarkdownParser {
    private static let maximumRenderedBytes = 256 * 1_024
    private static let maximumRenderedLines = 500
    private static let maximumRenderedPipes = 1_000
    private static let maximumInlineMarkers = 2_000
    public static let maximumRenderedTableCells = 1_000

    public static let maxBlockCacheEntries = 256
    public static let maxInlineCacheEntries = 1_024
    public static let maxCacheCostBytes = 4 * 1_024 * 1_024

    public static let blockCache = MarkdownLRUCache<[MarkdownBlock]>(
        maxEntries: maxBlockCacheEntries,
        maxCostBytes: maxCacheCostBytes
    )
    public static let inlineCache = MarkdownLRUCache<AttributedString>(
        maxEntries: maxInlineCacheEntries,
        maxCostBytes: maxCacheCostBytes
    )

    public static func clearCache() {
        blockCache.removeAll()
        inlineCache.removeAll()
    }

    public static func isWithinRenderingLimits(_ text: String) -> Bool {
        guard text.utf8.count <= maximumRenderedBytes else { return false }
        let normalized = normalizeLineEndings(text)
        var lines = 1
        var pipes = 0
        var inlineMarkers = 0
        for character in normalized {
            if character == "\n" {
                lines += 1
                if lines > maximumRenderedLines { return false }
            } else if character == "|" {
                pipes += 1
                if pipes > maximumRenderedPipes { return false }
            } else if character == "*" || character == "_" || character == "~"
                        || character == "`" || character == "[" || character == "<" {
                inlineMarkers += 1
                if inlineMarkers > maximumInlineMarkers { return false }
            }
        }
        return isWithinTableCellLimits(blocks(from: text))
    }

    public static func isWithinTableCellLimits(_ blocks: [MarkdownBlock]) -> Bool {
        var totalCells = 0
        for block in blocks {
            guard case let .table(table) = block else { continue }
            let columns = max(table.header.count, 1)
            for row in [table.header] + table.rows {
                let maxChars = row.prefix(columns).map(\.count).max() ?? 0
                let visualLines = max(1, (maxChars + 31) / 32)
                let (rowCells, overflow) = columns.multipliedReportingOverflow(by: visualLines)
                let (nextTotal, sumOverflow) = totalCells.addingReportingOverflow(rowCells)
                if overflow || sumOverflow || nextTotal > maximumRenderedTableCells { return false }
                totalCells = nextTotal
            }
        }
        return true
    }

    public static func blocks(from text: String) -> [MarkdownBlock] {
        blockCache.value(for: text, compute: parseBlocks(from:))
    }

    public static func inline(_ string: String) -> AttributedString {
        inlineCache.value(for: string, compute: parseInline(_:))
    }

    private static func parseInline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(string)
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func parseBlocks(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let normalized = normalizeLineEndings(text)
        let lines = normalized.components(separatedBy: "\n")
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceLength(trimmed) {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !isClosingFence(lines[index].trimmingCharacters(in: .whitespaces), fence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count {
                    index += 1
                }
                blocks.append(.codeBlock(code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let level = headingLevel(trimmed) {
                flushParagraph()
                let content = trimmed
                    .drop { $0 == "#" }
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: content))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quote.append(
                        String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if listItem(from: line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    let current = lines[index]
                    if let item = listItem(from: current) {
                        items.append(item)
                        index += 1
                    } else if !items.isEmpty,
                              !current.trimmingCharacters(in: .whitespaces).isEmpty,
                              !isBlockStart(current.trimmingCharacters(in: .whitespaces)) {
                        let last = items.removeLast()
                        let continued = current.trimmingCharacters(in: .whitespaces)
                        items.append(MarkdownListItem(
                            marker: last.marker,
                            text: last.text + " " + continued,
                            depth: last.depth
                        ))
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }

            if index + 1 < lines.count,
               rowContainsUnescapedPipe(trimmed),
               let alignments = tableDelimiterAlignments(
                   lines[index + 1].trimmingCharacters(in: .whitespaces)
               ),
               splitTableRow(trimmed).count == alignments.count {
                flushParagraph()
                let header = splitTableRow(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !rowLine.isEmpty,
                          rowContainsUnescapedPipe(rowLine) else {
                        break
                    }
                    if !rowLine.hasPrefix("|") {
                        if isBlockStart(rowLine) { break }
                        if let item = listItem(from: lines[index]),
                           !item.text.hasPrefix("|") {
                            break
                        }
                    }
                    rows.append(splitTableRow(rowLine))
                    index += 1
                }
                blocks.append(.table(MarkdownTable(
                    header: header,
                    alignments: alignments,
                    rows: rows
                )))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func fenceLength(_ line: String) -> Int? {
        let ticks = line.prefix { $0 == "`" }.count
        guard ticks >= 3, !line.dropFirst(ticks).contains("`") else { return nil }
        return ticks
    }

    private static func isClosingFence(_ line: String, _ openLength: Int) -> Bool {
        guard !line.isEmpty, line.allSatisfy({ $0 == "`" }) else { return false }
        return line.count >= openLength
    }

    private static func headingLevel(_ line: String) -> Int? {
        var hashes = 0
        for character in line {
            if character == "#" { hashes += 1 } else { break }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return hashes
    }

    private static func isBlockStart(_ trimmed: String) -> Bool {
        fenceLength(trimmed) != nil
            || headingLevel(trimmed) != nil
            || trimmed.hasPrefix(">")
    }

    private static func listItem(from line: String) -> MarkdownListItem? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let depth = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let body = line.dropFirst(leading.count)

        if let first = body.first, "-*+".contains(first) {
            let rest = body.dropFirst()
            guard rest.first == " " else { return nil }
            return MarkdownListItem(
                marker: "\u{2022}",
                text: rest.trimmingCharacters(in: .whitespaces),
                depth: depth
            )
        }

        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = body.dropFirst(digits.count)
            guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else {
                return nil
            }
            return MarkdownListItem(
                marker: "\(digits).",
                text: afterDigits.dropFirst().trimmingCharacters(in: .whitespaces),
                depth: depth
            )
        }

        return nil
    }

    private static func rowContainsUnescapedPipe(_ line: String) -> Bool {
        var backslashes = 0
        for character in line {
            if character == "|", backslashes % 2 == 0 { return true }
            backslashes = character == "\\" ? backslashes + 1 : 0
        }
        return false
    }

    public static func splitTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var backslashes = 0
        for character in line {
            if character == "|" {
                if backslashes % 2 == 0 {
                    cells.append(current)
                    current = ""
                } else {
                    current.removeLast()
                    current.append("|")
                }
            } else {
                current.append(character)
            }
            backslashes = character == "\\" ? backslashes + 1 : 0
        }
        cells.append(current)
        var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed.first == "" { trimmed.removeFirst() }
        if trimmed.last == "" { trimmed.removeLast() }
        return trimmed
    }

    public static func tableDelimiterAlignments(_ line: String) -> [MarkdownColumnAlignment]? {
        guard rowContainsUnescapedPipe(line) else { return nil }
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownColumnAlignment] = []
        for cell in cells {
            let leadingColon = cell.hasPrefix(":")
            let trailingColon = cell.hasSuffix(":")
            let dashes = cell.dropFirst(leadingColon ? 1 : 0)
                .dropLast(trailingColon ? 1 : 0)
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else {
                return nil
            }
            switch (leadingColon, trailingColon) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }
}

#if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)

#if canImport(UIKit) && !os(watchOS)
private typealias PlatformFont = UIFont
private typealias PlatformFontDescriptor = UIFontDescriptor
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
private typealias PlatformFont = NSFont
private typealias PlatformFontDescriptor = NSFontDescriptor
private typealias PlatformColor = NSColor
#endif

/// Renders a practical subset of Markdown (headings, ordered/unordered lists,
/// fenced code blocks, blockquotes, tables, plus inline emphasis, links, and
/// inline code) as native views with standard platform text selection controls.
public struct MarkdownText: View, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public static let quoteBarAttribute = NSAttributedString.Key(
        "CopilotProjects.MarkdownQuoteBar"
    )
    public static let tableHeaderDividerAttribute = NSAttributedString.Key(
        "CopilotProjects.MarkdownTableHeaderDivider"
    )
    fileprivate static let tableCellFragmentAttribute = NSAttributedString.Key(
        "CopilotProjects.MarkdownTableCellFragment"
    )
    fileprivate static let tableSeparatorPositionAttribute = NSAttributedString.Key(
        "CopilotProjects.MarkdownTableSeparatorPosition"
    )
    fileprivate static let tableRowBreakAttribute = NSAttributedString.Key("CopilotProjects.MarkdownTableRowBreak")
    fileprivate static let tableAccessibilityLabelAttribute = NSAttributedString.Key(
        "CopilotProjects.MarkdownTableAccessibilityLabel"
    )

    fileprivate struct TableCellFragment: Hashable {
        let row: Int
        let column: Int
        let fullCellText: String
        let rangeInCell: NSRange
    }

    fileprivate struct TableSeparatorPosition: Hashable {
        let row: Int
        let leftColumn: Int
        let rightColumn: Int
    }

    fileprivate struct TableHeaderDividerInfo: Hashable {
        let tableWidth: CGFloat
        let firstBodyRowCharacterIndex: Int
    }

    #if canImport(UIKit) && !os(watchOS)
    public static let headingLevelAttribute = NSAttributedString.Key.accessibilityTextHeadingLevel
    #else
    public static let headingLevelAttribute = NSAttributedString.Key("AXHeadingLevel")
    #endif

    private enum TextRole {
        case heading(Int)
        case body
        case footnote
    }

    fileprivate enum ProsePart: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([MarkdownListItem])
        case quote(String)
    }

    fileprivate enum RenderSegment: Equatable {
        case plain(String)
        case prose([ProsePart])
        case codeBlock(String)
        case table(MarkdownTable)
    }

    fileprivate struct RenderKey: Equatable {
        let segment: RenderSegment
        let styleContext: StyleContext
        let layoutDirection: LayoutDirection
    }

    fileprivate static func makeSegmentAttributedText(_ key: RenderKey) -> NSAttributedString {
        switch key.segment {
        case let .plain(text):
            makePlainAttributedText(text, styleContext: key.styleContext)
        case let .prose(parts):
            makeProseAttributedText(parts, styleContext: key.styleContext)
        case let .codeBlock(code):
            makeCodeBlockAttributedText(code, styleContext: key.styleContext)
        case let .table(table):
            makeTableAttributedText(table, styleContext: key.styleContext, layoutDirection: key.layoutDirection)
        }
    }

    public var body: some View {
        if !MarkdownParser.isWithinRenderingLimits(text) {
            SelectableMarkdownText(wraps: true, segment: .plain(text))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                let segments = Self.segments(from: MarkdownParser.blocks(from: text))
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    view(for: segment)
                }
            }
        }
    }

    private static func segments(from blocks: [MarkdownBlock]) -> [RenderSegment] {
        var result: [RenderSegment] = []
        var currentProse: [ProsePart] = []

        func flushProse() {
            guard !currentProse.isEmpty else { return }
            result.append(.prose(currentProse))
            currentProse = []
        }

        for block in blocks {
            switch block {
            case let .heading(level, text):
                currentProse.append(.heading(level: level, text: text))
            case let .paragraph(text):
                currentProse.append(.paragraph(text))
            case let .list(items):
                currentProse.append(.list(items))
            case let .quote(text):
                currentProse.append(.quote(text))
            case let .codeBlock(code):
                flushProse()
                result.append(.codeBlock(code))
            case let .table(table):
                flushProse()
                result.append(.table(table))
            }
        }
        flushProse()
        return result
    }

    @ViewBuilder
    private func view(for segment: RenderSegment) -> some View {
        switch segment {
        case .plain, .prose:
            SelectableMarkdownText(wraps: true, segment: segment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .codeBlock:
            ScrollView(.horizontal, showsIndicators: false) {
                SelectableMarkdownText(wraps: false, segment: segment)
                    .padding(10)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Self.containerBackgroundColor,
                in: RoundedRectangle(cornerRadius: 8)
            )
        case let .table(table):
            tableView(table)
        }
    }

    @ViewBuilder
    private func tableView(_ table: MarkdownTable) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SelectableMarkdownText(wraps: false, segment: .table(table))
                .padding(10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Self.containerBackgroundColor,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private static let cellWidth: CGFloat = 280
    private static let minCellWidth: CGFloat = 36
    private static let tableColumnSpacing: CGFloat = 14

    private static var containerBackgroundColor: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .tertiarySystemBackground)
        #else
        Color.primary.opacity(0.06)
        #endif
    }

    fileprivate static var primaryLabelColor: PlatformColor {
        #if canImport(UIKit) && !os(watchOS)
        .label
        #else
        .labelColor
        #endif
    }

    fileprivate static var secondaryLabelColor: PlatformColor {
        #if canImport(UIKit) && !os(watchOS)
        .secondaryLabel
        #else
        .secondaryLabelColor
        #endif
    }

    public static func resolvedTableTextAlignment(
        _ alignments: [MarkdownColumnAlignment],
        column: Int,
        layoutDirection: LayoutDirection
    ) -> NSTextAlignment {
        let isRTL = layoutDirection == .rightToLeft
        let columnAlignment = column < alignments.count ? alignments[column] : .leading
        switch columnAlignment {
        case .leading: return isRTL ? .right : .left
        case .center: return .center
        case .trailing: return isRTL ? .left : .right
        }
    }

    private func inline(_ string: String) -> AttributedString {
        MarkdownParser.inline(string)
    }

    fileprivate struct StyleContext: Equatable {
        let dynamicTypeSize: DynamicTypeSize
        let legibilityWeight: LegibilityWeight?

        #if canImport(UIKit) && !os(watchOS)
        var traitCollection: UITraitCollection {
            var traits: [UITraitCollection] = [
                UITraitCollection(
                    preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)
                ),
            ]
            if let legibilityWeight {
                traits.append(
                    UITraitCollection(
                        legibilityWeight: legibilityWeight == .bold ? .bold : .regular
                    )
                )
            }
            return UITraitCollection(traitsFrom: traits)
        }
        #endif
    }

    private static func makePlainAttributedText(
        _ string: String,
        styleContext: StyleContext
    ) -> NSAttributedString {
        let font = scaledSystemFont(
            role: .body,
            weight: .regular,
            styleContext: styleContext
        )
        let paragraphStyle = defaultParagraphStyle(
            alignment: .natural,
            wraps: true,
            firstLineHeadIndent: 0,
            headIndent: 0,
            tabStopLocation: nil,
            paragraphSpacing: 0
        )
        return NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: primaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private static func makeProseAttributedText(
        _ parts: [ProsePart],
        styleContext: StyleContext
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (partIndex, part) in parts.enumerated() {
            let isLastPart = partIndex == parts.count - 1
            switch part {
            case let .heading(level, text):
                let attributed = NSMutableAttributedString(
                    attributedString: makeAttributedText(
                        MarkdownParser.inline(text),
                        role: .heading(level),
                        weight: .semibold,
                        foregroundColor: primaryLabelColor,
                        alignment: .natural,
                        wraps: true,
                        trailingParagraphSpacing: isLastPart ? 0 : 8,
                        styleContext: styleContext
                    )
                )
                if attributed.length > 0 {
                    attributed.addAttribute(
                        headingLevelAttribute,
                        value: NSNumber(value: min(max(level, 1), 6)),
                        range: NSRange(location: 0, length: attributed.length)
                    )
                }
                result.append(attributed)
                if !isLastPart {
                    result.append(NSAttributedString(string: "\n"))
                }
            case let .paragraph(text):
                let attributed = makeAttributedText(
                    MarkdownParser.inline(text),
                    role: .body,
                    weight: .regular,
                    foregroundColor: primaryLabelColor,
                    alignment: .natural,
                    wraps: true,
                    trailingParagraphSpacing: isLastPart ? 0 : 8,
                    styleContext: styleContext
                )
                result.append(attributed)
                if !isLastPart {
                    result.append(NSAttributedString(string: "\n"))
                }
            case let .quote(text):
                let attributed = NSMutableAttributedString(
                    attributedString: makeAttributedText(
                        MarkdownParser.inline(text),
                        role: .body,
                        weight: .regular,
                        foregroundColor: secondaryLabelColor,
                        alignment: .natural,
                        wraps: true,
                        firstLineHeadIndent: 11,
                        headIndent: 11,
                        trailingParagraphSpacing: isLastPart ? 0 : 8,
                        styleContext: styleContext
                    )
                )
                if attributed.length > 0 {
                    attributed.addAttribute(
                        quoteBarAttribute,
                        value: partIndex + 1,
                        range: NSRange(location: 0, length: attributed.length)
                    )
                }
                result.append(attributed)
                if !isLastPart {
                    result.append(NSAttributedString(string: "\n"))
                }
            case let .list(items):
                for (itemIndex, item) in items.enumerated() {
                    let isLastItem = itemIndex == items.count - 1
                    let spacing: CGFloat = isLastItem ? (isLastPart ? 0 : 8) : 4
                    let attributedItem = makeListItemAttributedText(
                        item,
                        trailingParagraphSpacing: spacing,
                        styleContext: styleContext
                    )
                    result.append(attributedItem)
                    if !(isLastPart && isLastItem) {
                        result.append(NSAttributedString(string: "\n"))
                    }
                }
            }
        }
        return result
    }

    private static func makeListItemAttributedText(
        _ item: MarkdownListItem,
        trailingParagraphSpacing: CGFloat,
        styleContext: StyleContext
    ) -> NSAttributedString {
        let baseFont = scaledSystemFont(
            role: .body,
            weight: .regular,
            monospacedDigits: true,
            styleContext: styleContext
        )
        let baseIndent = CGFloat(min(item.depth, 6)) * 14
        let markerWidth = ceil(
            (item.marker as NSString).size(withAttributes: [.font: baseFont]).width
        )
        let textIndent = baseIndent + markerWidth + 8

        let bodyAttributed = makeAttributedText(
            MarkdownParser.inline(item.text),
            role: .body,
            weight: .regular,
            foregroundColor: primaryLabelColor,
            alignment: .natural,
            wraps: true,
            firstLineHeadIndent: baseIndent,
            headIndent: textIndent,
            tabStopLocation: textIndent,
            trailingParagraphSpacing: trailingParagraphSpacing,
            styleContext: styleContext
        )
        let itemParagraphStyle = (bodyAttributed.length > 0
            ? bodyAttributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            : nil) ?? defaultParagraphStyle(
                alignment: .natural,
                wraps: true,
                firstLineHeadIndent: baseIndent,
                headIndent: textIndent,
                tabStopLocation: textIndent,
                paragraphSpacing: trailingParagraphSpacing
            )

        let prefix = NSMutableAttributedString(
            string: "\(item.marker)\t",
            attributes: [
                .font: baseFont,
                .foregroundColor: secondaryLabelColor,
                .paragraphStyle: itemParagraphStyle,
            ]
        )
        prefix.append(bodyAttributed)
        return prefix
    }

    private static func makeCodeBlockAttributedText(
        _ code: String,
        styleContext: StyleContext
    ) -> NSAttributedString {
        let font = scaledMonospacedFont(
            role: .footnote,
            weight: .regular,
            styleContext: styleContext
        )
        let paragraphStyle = defaultParagraphStyle(
            alignment: .natural,
            wraps: false,
            firstLineHeadIndent: 0,
            headIndent: 0,
            tabStopLocation: nil,
            paragraphSpacing: 0
        )
        return NSAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: primaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private static func makeTableAttributedText(
        _ table: MarkdownTable,
        styleContext: StyleContext,
        layoutDirection: LayoutDirection
    ) -> NSAttributedString {
        let columns = max(table.header.count, 1)
        let headerCells: [NSAttributedString] = (0..<columns).map { column in
            let text = column < table.header.count ? table.header[column] : ""
            return makeAttributedText(
                MarkdownParser.inline(text.replacingOccurrences(of: "\t", with: "    ")),
                role: .body,
                weight: .semibold,
                foregroundColor: primaryLabelColor,
                alignment: .natural,
                wraps: true,
                styleContext: styleContext
            )
        }
        let bodyRows: [[NSAttributedString]] = table.rows.map { row in
            (0..<columns).map { column in
                let text = column < row.count ? row[column] : ""
                return makeAttributedText(
                    MarkdownParser.inline(text.replacingOccurrences(of: "\t", with: "    ")),
                    role: .body,
                    weight: .regular,
                    foregroundColor: primaryLabelColor,
                    alignment: .natural,
                    wraps: true,
                    styleContext: styleContext
                )
            }
        }

        let columnWidths: [CGFloat] = (0..<columns).map { column in
            var widest = minCellWidth
            for cell in [headerCells[column]] + bodyRows.map({ $0[column] }) where cell.length > 0 {
                let measured = ceil(
                    cell.boundingRect(
                        with: CGSize(
                            width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude
                        ),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        context: nil
                    ).width
                )
                widest = max(widest, min(cellWidth, measured))
            }
            return widest
        }

        var columnOrigins: [CGFloat] = []
        var runningX: CGFloat = 0
        for (column, width) in columnWidths.enumerated() {
            columnOrigins.append(runningX)
            runningX += width + (column < columns - 1 ? tableColumnSpacing : 0)
        }

        let firstColumnResolvedAlignment = resolvedTableTextAlignment(
            table.alignments,
            column: 0,
            layoutDirection: layoutDirection
        )
        let usesLeadingTabForFirstColumn = columns > 1 && firstColumnResolvedAlignment != .left
        let tabStopColumns = usesLeadingTabForFirstColumn ? Array(0..<columns) : Array(1..<columns)
        let tabStops: [NSTextTab] = tabStopColumns.map { column in
            let alignment = resolvedTableTextAlignment(
                table.alignments,
                column: column,
                layoutDirection: layoutDirection
            )
            let location: CGFloat = switch alignment {
            case .center:
                columnOrigins[column] + columnWidths[column] / 2
            case .right:
                columnOrigins[column] + columnWidths[column]
            default:
                columnOrigins[column]
            }
            return NSTextTab(textAlignment: alignment, location: location)
        }
        let paragraphAlignment: NSTextAlignment = columns == 1 ? firstColumnResolvedAlignment : .left

        let allRows = [headerCells] + bodyRows
        let logicalAccessibilityText = allRows.map { rowCells in
            rowCells.map(\.string).joined(separator: "\t")
        }.joined(separator: "\n")
        let result = NSMutableAttributedString()
        let fallbackFont = scaledSystemFont(
            role: .body,
            weight: .regular,
            styleContext: styleContext
        )
        var firstBodyRowCharIndex: Int?
        var totalVisualCells = 0

        for (rowIndex, rowCells) in allRows.enumerated() {
            let isHeader = rowIndex == 0
            let isLastRow = rowIndex == allRows.count - 1
            if rowIndex == 1 {
                firstBodyRowCharIndex = result.length
            }
            let remainingVisualLines = (MarkdownParser.maximumRenderedTableCells - totalVisualCells) / columns
            let wrappedColumns: [[NSAttributedString]] = remainingVisualLines < 1 ? [] : (0..<columns).map { column in
                wrapCellIntoLines(
                    rowCells[column],
                    width: columnWidths[column],
                    row: rowIndex,
                    column: column,
                    maxLines: remainingVisualLines
                )
            }
            let visualLineCount = max(1, wrappedColumns.map(\.count).max() ?? 1)
            guard visualLineCount <= remainingVisualLines else {
                return makePlainAttributedText(logicalAccessibilityText, styleContext: styleContext)
            }
            totalVisualCells += columns * visualLineCount

            for lineIndex in 0..<visualLineCount {
                let isLastVisualLine = lineIndex == visualLineCount - 1
                let spacingAfterLine: CGFloat = if !isLastVisualLine {
                    0
                } else if isLastRow {
                    0
                } else if isHeader {
                    12
                } else {
                    6
                }
                let lineStyle = NSMutableParagraphStyle()
                lineStyle.alignment = paragraphAlignment
                lineStyle.baseWritingDirection = .leftToRight
                lineStyle.lineBreakMode = .byClipping
                lineStyle.paragraphSpacing = spacingAfterLine
                lineStyle.tabStops = tabStops

                let lineAttributed = NSMutableAttributedString()
                if usesLeadingTabForFirstColumn {
                    lineAttributed.append(
                        NSAttributedString(
                            string: "\t",
                            attributes: [
                                .font: fallbackFont,
                                .foregroundColor: primaryLabelColor,
                            ]
                        )
                    )
                }
                for column in 0..<columns {
                    if column > 0 {
                        lineAttributed.append(
                            NSAttributedString(
                                string: "\t",
                                attributes: [
                                    .font: fallbackFont,
                                    .foregroundColor: primaryLabelColor,
                                    tableSeparatorPositionAttribute: TableSeparatorPosition(
                                        row: rowIndex,
                                        leftColumn: column - 1,
                                        rightColumn: column
                                    ),
                                ]
                            )
                        )
                    }
                    let columnLines = wrappedColumns[column]
                    if lineIndex < columnLines.count {
                        lineAttributed.append(columnLines[lineIndex])
                    }
                }
                if lineAttributed.length == 0 {
                    lineAttributed.append(
                        NSAttributedString(
                            string: " ",
                            attributes: [
                                .font: fallbackFont,
                                .foregroundColor: primaryLabelColor,
                                tableSeparatorPositionAttribute: TableSeparatorPosition(
                                    row: rowIndex,
                                    leftColumn: 0,
                                    rightColumn: 0
                                ),
                            ]
                        )
                    )
                }
                lineAttributed.addAttribute(
                    .paragraphStyle,
                    value: lineStyle,
                    range: NSRange(location: 0, length: lineAttributed.length)
                )
                result.append(lineAttributed)
                if !(isLastRow && isLastVisualLine) {
                    var breakAttributes: [NSAttributedString.Key: Any] = [
                        .font: fallbackFont,
                        .foregroundColor: primaryLabelColor,
                        .paragraphStyle: lineStyle,
                    ]
                    if isLastVisualLine {
                        breakAttributes[tableRowBreakAttribute] = rowIndex
                    }
                    result.append(
                        NSAttributedString(
                            string: "\n",
                            attributes: breakAttributes
                        )
                    )
                }
            }
        }

        if result.length > 0 {
            let fullRange = NSRange(location: 0, length: result.length)
            result.addAttribute(
                tableAccessibilityLabelAttribute,
                value: logicalAccessibilityText,
                range: fullRange
            )
            result.addAttribute(
                tableHeaderDividerAttribute,
                value: TableHeaderDividerInfo(
                    tableWidth: max(runningX, 1),
                    firstBodyRowCharacterIndex: firstBodyRowCharIndex ?? -1
                ),
                range: NSRange(location: 0, length: 1)
            )
        }

        return result
    }

    private static func wrapCellIntoLines(
        _ cell: NSAttributedString,
        width: CGFloat,
        row: Int,
        column: Int,
        maxLines: Int
    ) -> [NSAttributedString] {
        let fullText = cell.string
        guard cell.length > 0 else { return [NSAttributedString()] }
        let singleLineWidth = ceil(
            cell.boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).width
        )
        if singleLineWidth <= width && !fullText.contains("\n") {
            let annotated = NSMutableAttributedString(attributedString: cell)
            annotated.addAttribute(
                tableCellFragmentAttribute,
                value: TableCellFragment(
                    row: row,
                    column: column,
                    fullCellText: fullText,
                    rangeInCell: NSRange(location: 0, length: cell.length)
                ),
                range: NSRange(location: 0, length: annotated.length)
            )
            return [annotated]
        }

        let storage = NSTextStorage(attributedString: cell)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        var lines: [NSAttributedString] = []
        let totalGlyphs = layoutManager.numberOfGlyphs
        var glyphIndex = 0
        let nsString = storage.string as NSString
        while glyphIndex < totalGlyphs {
            var lineGlyphRange = NSRange(location: 0, length: 0)
            _ = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange
            )
            guard lineGlyphRange.length > 0 else { break }
            var charRange = layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            while charRange.length > 0 {
                let lastChar = nsString.character(at: NSMaxRange(charRange) - 1)
                if lastChar == 0x0A || lastChar == 0x0D
                    || ((lastChar == 0x20 || lastChar == 0x09)
                        && charRange.length > 1
                        && NSMaxRange(lineGlyphRange) < totalGlyphs) {
                    charRange.length -= 1
                } else {
                    break
                }
            }
            let slice = NSMutableAttributedString(
                attributedString: storage.attributedSubstring(from: charRange)
            )
            if slice.length > 0 {
                slice.addAttribute(
                    tableCellFragmentAttribute,
                    value: TableCellFragment(
                        row: row,
                        column: column,
                        fullCellText: fullText,
                        rangeInCell: charRange
                    ),
                    range: NSRange(location: 0, length: slice.length)
                )
            }
            lines.append(slice)
            if lines.count > maxLines {
                break
            }
            glyphIndex = NSMaxRange(lineGlyphRange)
        }
        return lines.isEmpty ? [NSAttributedString()] : lines
    }

    fileprivate static func accessibilityText(for attributedText: NSAttributedString) -> String {
        if attributedText.length > 0,
           let tableLabel = attributedText.attribute(
               tableAccessibilityLabelAttribute,
               at: 0,
               effectiveRange: nil
           ) as? String {
            return tableLabel
        }
        return attributedText.string
    }

    fileprivate static func tableCopiedText(
        from attributedText: NSAttributedString,
        in selectedRange: NSRange
    ) -> String? {
        guard selectedRange.length > 0,
              NSMaxRange(selectedRange) <= attributedText.length else {
            return nil
        }
        let fullRange = NSRange(location: 0, length: attributedText.length)
        struct CellSpan {
            let fullCellText: String
            var start: Int
            var end: Int
        }
        var rows: [Int: [Int: CellSpan]] = [:]
        var rowCharSpans: [Int: (start: Int, end: Int)] = [:]

        attributedText.enumerateAttribute(
            tableCellFragmentAttribute,
            in: fullRange
        ) { value, attrRange, _ in
            guard let fragment = value as? TableCellFragment else { return }
            let overlap = NSIntersectionRange(selectedRange, attrRange)
            guard overlap.length > 0 else { return }
            if let existingSpan = rowCharSpans[fragment.row] {
                rowCharSpans[fragment.row] = (
                    start: min(existingSpan.start, overlap.location),
                    end: max(existingSpan.end, NSMaxRange(overlap))
                )
            } else {
                rowCharSpans[fragment.row] = (
                    start: overlap.location,
                    end: NSMaxRange(overlap)
                )
            }
            let cellLength = (fragment.fullCellText as NSString).length
            let startOffset = overlap.location - attrRange.location
            let endOffset = startOffset + overlap.length
            let startInCell = min(max(0, fragment.rangeInCell.location + startOffset), cellLength)
            let endInCell = min(
                max(startInCell, fragment.rangeInCell.location + min(endOffset, fragment.rangeInCell.length)),
                cellLength
            )
            if var existing = rows[fragment.row]?[fragment.column] {
                existing.start = min(existing.start, startInCell)
                existing.end = max(existing.end, endInCell)
                rows[fragment.row]?[fragment.column] = existing
            } else {
                rows[fragment.row, default: [:]][fragment.column] = CellSpan(
                    fullCellText: fragment.fullCellText,
                    start: startInCell,
                    end: endInCell
                )
            }
        }

        attributedText.enumerateAttribute(
            tableSeparatorPositionAttribute,
            in: selectedRange
        ) { value, attrRange, _ in
            guard let separator = value as? TableSeparatorPosition else { return }
            if let charSpan = rowCharSpans[separator.row],
               attrRange.location >= charSpan.start,
               NSMaxRange(attrRange) <= charSpan.end {
                return
            }
            if rows[separator.row]?[separator.leftColumn] == nil {
                rows[separator.row, default: [:]][separator.leftColumn] = CellSpan(
                    fullCellText: "",
                    start: 0,
                    end: 0
                )
            }
            if rows[separator.row]?[separator.rightColumn] == nil {
                rows[separator.row, default: [:]][separator.rightColumn] = CellSpan(
                    fullCellText: "",
                    start: 0,
                    end: 0
                )
            }
        }

        let sortedRows = rows.keys.sorted()
        guard let minRow = sortedRows.first, let maxRow = sortedRows.last else {
            return nil
        }

        var hasLeadingRowBreak = false
        var hasTrailingRowBreak = false
        attributedText.enumerateAttribute(tableRowBreakAttribute, in: selectedRange) { value, _, _ in
            guard let breakRow = value as? Int else { return }
            if breakRow < minRow { hasLeadingRowBreak = true }
            if breakRow >= maxRow { hasTrailingRowBreak = true }
        }

        let body = sortedRows.map { rowIndex in
            let rowCells = rows[rowIndex] ?? [:]
            guard let minCol = rowCells.keys.min(),
                  let maxCol = rowCells.keys.max() else {
                return ""
            }
            return (minCol...maxCol).map { columnIndex in
                guard let span = rowCells[columnIndex] else { return "" }
                let cellNS = span.fullCellText as NSString
                let safeStart = min(max(0, span.start), cellNS.length)
                let safeEnd = min(max(safeStart, span.end), cellNS.length)
                return cellNS.substring(with: NSRange(location: safeStart, length: safeEnd - safeStart))
            }.joined(separator: "\t")
        }.joined(separator: "\n")
        return (hasLeadingRowBreak ? "\n" : "") + body + (hasTrailingRowBreak ? "\n" : "")
    }

    fileprivate static func copiedText(
        from attributedText: NSAttributedString,
        in selectedRange: NSRange
    ) -> String {
        guard selectedRange.length > 0,
              NSMaxRange(selectedRange) <= attributedText.length else {
            return ""
        }
        return tableCopiedText(from: attributedText, in: selectedRange)
            ?? (attributedText.string as NSString).substring(with: selectedRange)
    }

    private static func makeAttributedText(
        _ content: AttributedString,
        role: TextRole,
        weight: PlatformFont.Weight,
        foregroundColor: PlatformColor,
        alignment: NSTextAlignment,
        wraps: Bool,
        firstLineHeadIndent: CGFloat = 0,
        headIndent: CGFloat = 0,
        tabStopLocation: CGFloat? = nil,
        trailingParagraphSpacing: CGFloat = 0,
        styleContext: StyleContext
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseParagraphStyle = defaultParagraphStyle(
            alignment: alignment,
            wraps: wraps,
            firstLineHeadIndent: firstLineHeadIndent,
            headIndent: headIndent,
            tabStopLocation: tabStopLocation,
            paragraphSpacing: 0
        )

        for run in content.runs {
            let substring = String(content[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font: PlatformFont
            if intent.contains(.code) {
                font = scaledMonospacedFont(
                    role: role,
                    weight: intent.contains(.stronglyEmphasized) ? .bold : weight,
                    styleContext: styleContext
                )
            } else {
                font = scaledSystemFont(
                    role: role,
                    weight: weight,
                    bold: intent.contains(.stronglyEmphasized),
                    styleContext: styleContext
                )
            }
            if intent.contains(.emphasized) {
                font = applyingItalicTrait(to: font)
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foregroundColor,
                .paragraphStyle: baseParagraphStyle,
            ]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: substring, attributes: attributes))
        }

        if result.length > 0 {
            let nsString = result.string as NSString
            let lastBreak = nsString.range(of: "\n", options: .backwards)
            let lastParagraphStart = lastBreak.location == NSNotFound ? 0 : lastBreak.location + 1
            let lastParagraphRange = NSRange(
                location: lastParagraphStart,
                length: nsString.length - lastParagraphStart
            )
            let trailingStyle = defaultParagraphStyle(
                alignment: alignment,
                wraps: wraps,
                firstLineHeadIndent: lastParagraphStart == 0 ? firstLineHeadIndent : headIndent,
                headIndent: headIndent,
                tabStopLocation: tabStopLocation,
                paragraphSpacing: trailingParagraphSpacing
            )
            result.addAttribute(.paragraphStyle, value: trailingStyle, range: lastParagraphRange)

            if lastParagraphStart > 0 && firstLineHeadIndent != headIndent {
                let firstBreak = nsString.range(of: "\n")
                if firstBreak.location != NSNotFound && firstBreak.location + 1 < lastParagraphStart {
                    let middleRange = NSRange(
                        location: firstBreak.location + 1,
                        length: lastParagraphStart - (firstBreak.location + 1)
                    )
                    let middleStyle = defaultParagraphStyle(
                        alignment: alignment,
                        wraps: wraps,
                        firstLineHeadIndent: headIndent,
                        headIndent: headIndent,
                        tabStopLocation: tabStopLocation,
                        paragraphSpacing: 0
                    )
                    result.addAttribute(.paragraphStyle, value: middleStyle, range: middleRange)
                }
            }
        }

        return result
    }

    private static func defaultParagraphStyle(
        alignment: NSTextAlignment,
        wraps: Bool,
        firstLineHeadIndent: CGFloat,
        headIndent: CGFloat,
        tabStopLocation: CGFloat?,
        paragraphSpacing: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        style.firstLineHeadIndent = firstLineHeadIndent
        style.headIndent = headIndent
        style.paragraphSpacing = paragraphSpacing
        if let tabStopLocation {
            style.tabStops = [NSTextTab(textAlignment: .left, location: tabStopLocation)]
        }
        return style
    }

    private static func effectiveFontWeight(
        _ weight: PlatformFont.Weight,
        bold: Bool = false,
        styleContext: StyleContext
    ) -> PlatformFont.Weight {
        let baseWeight: PlatformFont.Weight = bold ? .bold : weight
        guard styleContext.legibilityWeight == .bold else {
            return baseWeight
        }
        switch baseWeight {
        case .regular: return .semibold
        case .medium, .semibold: return .bold
        default: return .heavy
        }
    }

    private static func pointSize(
        for role: TextRole,
        styleContext: StyleContext
    ) -> CGFloat {
        #if canImport(UIKit) && !os(watchOS)
        let textStyle: UIFont.TextStyle = switch role {
        case .heading(1): .title2
        case .heading(2): .title3
        case .heading(3): .headline
        case .heading: .subheadline
        case .body: .body
        case .footnote: .footnote
        }
        return UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: textStyle,
            compatibleWith: styleContext.traitCollection
        ).pointSize
        #else
        let textStyle: NSFont.TextStyle = switch role {
        case .heading(1): .title2
        case .heading(2): .title3
        case .heading(3): .headline
        case .heading: .subheadline
        case .body: .body
        case .footnote: .footnote
        }
        return NSFont.preferredFont(forTextStyle: textStyle).pointSize
        #endif
    }

    private static func scaledSystemFont(
        role: TextRole,
        weight: PlatformFont.Weight,
        bold: Bool = false,
        monospacedDigits: Bool = false,
        styleContext: StyleContext
    ) -> PlatformFont {
        let size = pointSize(for: role, styleContext: styleContext)
        let effectiveWeight = effectiveFontWeight(
            weight,
            bold: bold,
            styleContext: styleContext
        )
        return monospacedDigits
            ? PlatformFont.monospacedDigitSystemFont(ofSize: size, weight: effectiveWeight)
            : PlatformFont.systemFont(ofSize: size, weight: effectiveWeight)
    }

    private static func scaledMonospacedFont(
        role: TextRole,
        weight: PlatformFont.Weight,
        styleContext: StyleContext
    ) -> PlatformFont {
        let size = pointSize(for: role, styleContext: styleContext)
        return PlatformFont.monospacedSystemFont(
            ofSize: size,
            weight: effectiveFontWeight(weight, styleContext: styleContext)
        )
    }

    private static func applyingItalicTrait(to font: PlatformFont) -> PlatformFont {
        #if canImport(UIKit) && !os(watchOS)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.italic)
        )
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
/// A read-only `UITextView` that provides standard iOS text selection controls
/// (word/range highlighting, draggable grabber handles, and the system edit menu)
/// without scrolling independently or clipping selection handles.
public final class MarkdownSelectableTextView: UITextView {
    public var wrapsText = true
    fileprivate var renderKey: MarkdownText.RenderKey?
    public var preferredMaxLayoutWidth: CGFloat = 0 {
        didSet {
            if abs(oldValue - preferredMaxLayoutWidth) > 0.5 {
                invalidateIntrinsicContentSize()
            }
        }
    }

    fileprivate var minimumTableWidth: CGFloat {
        guard let attributedText, attributedText.length > 0,
              let info = attributedText.attribute(
                  MarkdownText.tableHeaderDividerAttribute,
                  at: 0,
                  effectiveRange: nil
              ) as? MarkdownText.TableHeaderDividerInfo else { return 0 }
        return ceil(info.tableWidth)
    }

    public func selectedCopiedText() -> String {
        guard let attributedText else { return "" }
        return MarkdownText.copiedText(from: attributedText, in: selectedRange)
    }

    public func headerDividerY() -> CGFloat? {
        guard let attributedText, attributedText.length > 0,
              let info = attributedText.attribute(
                  MarkdownText.tableHeaderDividerAttribute,
                  at: 0,
                  effectiveRange: nil
              ) as? MarkdownText.TableHeaderDividerInfo,
              info.firstBodyRowCharacterIndex > 0,
              info.firstBodyRowCharacterIndex < attributedText.length,
              let bodyStart = position(
                  from: beginningOfDocument,
                  offset: info.firstBodyRowCharacterIndex
              ) else { return nil }
        let bodyRect = caretRect(for: bodyStart)
        guard bodyRect.minY.isFinite, bodyRect.minY > 6 else { return nil }
        return bodyRect.minY - 6
    }

    public override func copy(_ sender: Any?) {
        if let attributedText,
           let tableCopied = MarkdownText.tableCopiedText(from: attributedText, in: selectedRange) {
            UIPasteboard.general.string = tableCopied
        } else {
            super.copy(sender)
        }
    }

    public override var intrinsicContentSize: CGSize {
        let targetWidth = wrapsText && preferredMaxLayoutWidth > 0
            ? preferredMaxLayoutWidth
            : CGFloat.greatestFiniteMagnitude
        return measuredSize(forWidth: targetWidth)
    }

    func measuredSize(forWidth width: CGFloat) -> CGSize {
        let finiteWidth = wrapsText && width.isFinite && width > 0
            && width < CGFloat.greatestFiniteMagnitude
        let naturalWidth: CGFloat
        if finiteWidth {
            naturalWidth = width
        } else {
            let bounded = (attributedText ?? NSAttributedString()).boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).width
            naturalWidth = max(ceil(bounded), minimumTableWidth)
        }
        let measured = sizeThatFits(
            CGSize(width: max(1, naturalWidth), height: .greatestFiniteMagnitude)
        )
        return CGSize(width: naturalWidth, height: ceil(measured.height))
    }

    public override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let attributedText, attributedText.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.enumerateAttribute(
            MarkdownText.quoteBarAttribute,
            in: fullRange
        ) { value, range, _ in
            guard value != nil,
                  let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: range.length),
                  let textRange = textRange(from: start, to: end) else { return }
            let rects = selectionRects(for: textRange)
                .map(\.rect)
                .filter { !$0.height.isZero && !$0.height.isInfinite }
            guard let minY = rects.map(\.minY).min(),
                  let maxY = rects.map(\.maxY).max(),
                  maxY > minY else { return }
            let barX = effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? bounds.maxX - 3
                : 0
            let barRect = CGRect(x: barX, y: minY, width: 3, height: maxY - minY)
            UIColor.secondaryLabel.setFill()
            UIBezierPath(roundedRect: barRect, cornerRadius: 2).fill()
        }
        if let dividerY = headerDividerY() {
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let thickness = 1 / max(scale, 1)
            let lineRect = CGRect(
                x: 0,
                y: dividerY,
                width: max(bounds.width, minimumTableWidth),
                height: thickness
            )
            UIColor.separator.setFill()
            UIRectFill(lineRect)
        }
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, selectedRange.length > 0 {
            selectedRange = NSRange(location: 0, length: 0)
        }
        return resigned
    }
}

private struct SelectableMarkdownText: UIViewRepresentable {
    let wraps: Bool
    let segment: MarkdownText.RenderSegment

    private func renderKey(context: Context) -> MarkdownText.RenderKey {
        MarkdownText.RenderKey(
            segment: segment,
            styleContext: MarkdownText.StyleContext(
                dynamicTypeSize: context.environment.dynamicTypeSize,
                legibilityWeight: context.environment.legibilityWeight
            ),
            layoutDirection: context.environment.layoutDirection
        )
    }

    func makeUIView(context: Context) -> MarkdownSelectableTextView {
        let key = renderKey(context: context)
        let attributedText = MarkdownText.makeSegmentAttributedText(key)
        let textView = MarkdownSelectableTextView()
        textView.renderKey = key
        textView.wrapsText = wraps
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.contentMode = .redraw
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        textView.clipsToBounds = false
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = []
        textView.textDragInteraction?.isEnabled = false
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(
            wraps ? .defaultLow : .required,
            for: .horizontal
        )
        textView.attributedText = attributedText
        textView.accessibilityLabel = MarkdownText.accessibilityText(for: attributedText)
        return textView
    }

    func updateUIView(_ uiView: MarkdownSelectableTextView, context: Context) {
        let key = renderKey(context: context)
        uiView.wrapsText = wraps
        uiView.textContainer.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        guard uiView.renderKey != key else { return }
        uiView.renderKey = key
        let attributedText = MarkdownText.makeSegmentAttributedText(key)
        if uiView.attributedText != attributedText {
            let previousSelection = uiView.selectedRange
            let previousString = uiView.attributedText.string as NSString
            let nextString = attributedText.string as NSString
            uiView.attributedText = attributedText
            uiView.accessibilityLabel = MarkdownText.accessibilityText(for: attributedText)
            if previousSelection.length > 0,
               NSMaxRange(previousSelection) <= nextString.length,
               previousString.substring(with: previousSelection) == nextString.substring(with: previousSelection) {
                uiView.selectedRange = previousSelection
            } else if uiView.selectedRange.location != 0 || uiView.selectedRange.length != 0 {
                uiView.selectedRange = NSRange(location: 0, length: 0)
            }
            uiView.invalidateIntrinsicContentSize()
            uiView.setNeedsDisplay()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MarkdownSelectableTextView,
        context: Context
    ) -> CGSize? {
        if wraps {
            if let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0 {
                uiView.preferredMaxLayoutWidth = proposedWidth
                return uiView.measuredSize(forWidth: proposedWidth)
            }
            let fallbackWidth = uiView.preferredMaxLayoutWidth > 0
                ? uiView.preferredMaxLayoutWidth
                : CGFloat.greatestFiniteMagnitude
            let measured = uiView.measuredSize(forWidth: fallbackWidth)
            return CGSize(
                width: uiView.preferredMaxLayoutWidth > 0 ? fallbackWidth : measured.width,
                height: measured.height
            )
        } else {
            return uiView.measuredSize(forWidth: CGFloat.greatestFiniteMagnitude)
        }
    }
}

#elseif canImport(AppKit)

private final class MarkdownLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        let isUnemphasizedSelection = color == .unemphasizedSelectedContentBackgroundColor
            || color == .unemphasizedSelectedTextBackgroundColor
        let windowIsKey = firstTextView?.window?.isKeyWindow ?? true
        if isUnemphasizedSelection, windowIsKey {
            let activeColor = NSColor.selectedTextBackgroundColor
            activeColor.set()
            super.fillBackgroundRectArray(
                rectArray,
                count: rectCount,
                forCharacterRange: charRange,
                color: activeColor
            )
        } else {
            super.fillBackgroundRectArray(
                rectArray,
                count: rectCount,
                forCharacterRange: charRange,
                color: color
            )
        }
    }
}

/// A read-only `NSTextView` that provides standard macOS text selection controls
/// across contiguous Markdown blocks and peer transcript text views without scrolling independently.
public final class MarkdownSelectableTextView: NSTextView {
    private struct SelectionPosition: Comparable {
        let viewIndex: Int
        let charIndex: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.viewIndex != rhs.viewIndex {
                return lhs.viewIndex < rhs.viewIndex
            }
            return lhs.charIndex < rhs.charIndex
        }
    }

    private struct SelectionAnchor {
        weak var scopeRoot: NSView?
        weak var view: MarkdownSelectableTextView?
        let range: NSRange
    }

    @MainActor private static var isPreservingCrossViewSelection = false
    @MainActor private static var lastSelectionAnchor: SelectionAnchor?

    public var wrapsText = true
    fileprivate var renderKey: MarkdownText.RenderKey?
    public var preferredMaxLayoutWidth: CGFloat = 0 {
        didSet {
            if abs(oldValue - preferredMaxLayoutWidth) > 0.5 {
                invalidateIntrinsicContentSize()
            }
        }
    }

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        installMarkdownLayoutManagerIfNeeded()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installMarkdownLayoutManagerIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func installMarkdownLayoutManagerIfNeeded() {
        if !(layoutManager is MarkdownLayoutManager) {
            textContainer?.replaceLayoutManager(MarkdownLayoutManager())
        }
    }

    public var attributedText: NSAttributedString {
        get { textStorage ?? NSAttributedString() }
        set {
            textStorage?.setAttributedString(newValue)
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    fileprivate var hasActiveSelection: Bool {
        selectedRanges.contains(where: { $0.rangeValue.length > 0 })
    }

    fileprivate var selectionScopeRoot: NSView {
        let skippedHorizontalScrollView = wrapsText ? nil : enclosingScrollView
        var current: NSView? = self
        var outermostScrollView: NSScrollView?
        var topView: NSView = self
        while let view = current {
            if let scrollView = view as? NSScrollView, scrollView !== skippedHorizontalScrollView {
                outermostScrollView = scrollView
            }
            topView = view
            current = view.superview
        }
        return outermostScrollView?.documentView ?? outermostScrollView ?? window?.contentView ?? topView
    }

    public static func peerSelectableTextViews(in root: NSView) -> [MarkdownSelectableTextView] {
        var collected: [MarkdownSelectableTextView] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if let selectable = view as? MarkdownSelectableTextView {
                if selectable.attributedText.length > 0 {
                    collected.append(selectable)
                }
                return
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(root)
        return collected.sorted { lhs, rhs in
            let lhsRect = topDownRect(root.convert(lhs.bounds, from: lhs), in: root)
            let rhsRect = topDownRect(root.convert(rhs.bounds, from: rhs), in: root)
            if abs(lhsRect.minY - rhsRect.minY) > 0.5 {
                return lhsRect.minY < rhsRect.minY
            }
            return lhsRect.minX < rhsRect.minX
        }
    }

    private static func topDownRect(_ rectInRoot: NSRect, in root: NSView) -> NSRect {
        guard !root.isFlipped else { return rectInRoot }
        return NSRect(
            x: rectInRoot.minX,
            y: -rectInRoot.maxY,
            width: rectInRoot.width,
            height: rectInRoot.height
        )
    }

    private static func topDownPoint(_ pointInRoot: NSPoint, in root: NSView) -> NSPoint {
        guard !root.isFlipped else { return pointInRoot }
        return NSPoint(x: pointInRoot.x, y: -pointInRoot.y)
    }

    private static func selectionPosition(
        at pointInRoot: NSPoint,
        in views: [MarkdownSelectableTextView],
        scopeRoot: NSView
    ) -> SelectionPosition {
        guard !views.isEmpty else {
            return SelectionPosition(viewIndex: 0, charIndex: 0)
        }
        let cursorY = topDownPoint(pointInRoot, in: scopeRoot).y
        for (index, view) in views.enumerated() {
            let rect = topDownRect(scopeRoot.convert(view.bounds, from: view), in: scopeRoot)
            if cursorY <= rect.maxY {
                if cursorY < rect.minY {
                    return SelectionPosition(viewIndex: index, charIndex: 0)
                }
                if let textContainer = view.textContainer {
                    view.layoutManager?.ensureLayout(for: textContainer)
                }
                let localPoint = view.convert(pointInRoot, from: scopeRoot)
                let charIndex = min(
                    max(0, view.characterIndexForInsertion(at: localPoint)),
                    view.attributedText.length
                )
                return SelectionPosition(viewIndex: index, charIndex: charIndex)
            }
        }
        let lastIndex = views.count - 1
        return SelectionPosition(
            viewIndex: lastIndex,
            charIndex: views[lastIndex].attributedText.length
        )
    }

    private func resolvedAnchorRange(
        at charIndex: Int,
        granularity: NSSelectionGranularity
    ) -> NSRange {
        let clamped = min(max(0, charIndex), attributedText.length)
        let proposed = NSRange(location: clamped, length: 0)
        guard granularity != .selectByCharacter else { return proposed }
        return selectionRange(forProposedRange: proposed, granularity: granularity)
    }

    private static func updateCrossViewSelection(
        anchor: SelectionAnchor,
        pointInRoot: NSPoint,
        granularity: NSSelectionGranularity,
        in scopeRoot: NSView
    ) {
        let views = peerSelectableTextViews(in: scopeRoot)
        guard let anchorView = anchor.view,
              let anchorViewIndex = views.firstIndex(where: { $0 === anchorView }) else {
            return
        }
        let targetPos = selectionPosition(at: pointInRoot, in: views, scopeRoot: scopeRoot)
        let targetView = views[targetPos.viewIndex]
        let targetRange = targetView.resolvedAnchorRange(
            at: targetPos.charIndex,
            granularity: granularity
        )

        let anchorLength = anchorView.attributedText.length
        let safeAnchorStart = min(max(0, anchor.range.location), anchorLength)
        let safeAnchorEnd = min(max(safeAnchorStart, NSMaxRange(anchor.range)), anchorLength)
        let anchorStart = SelectionPosition(viewIndex: anchorViewIndex, charIndex: safeAnchorStart)
        let anchorEnd = SelectionPosition(viewIndex: anchorViewIndex, charIndex: safeAnchorEnd)
        let targetStart = SelectionPosition(viewIndex: targetPos.viewIndex, charIndex: targetRange.location)
        let targetEnd = SelectionPosition(viewIndex: targetPos.viewIndex, charIndex: NSMaxRange(targetRange))

        let lower: SelectionPosition
        let upper: SelectionPosition
        if targetStart < anchorStart {
            lower = targetStart
            upper = anchorEnd
        } else {
            lower = anchorStart
            upper = targetEnd
        }

        for (index, view) in views.enumerated() {
            let length = view.attributedText.length
            let range: NSRange
            if index < lower.viewIndex || index > upper.viewIndex {
                range = NSRange(location: 0, length: 0)
            } else if lower.viewIndex == upper.viewIndex {
                let start = min(max(0, lower.charIndex), length)
                let end = min(max(start, upper.charIndex), length)
                range = NSRange(location: start, length: end - start)
            } else if index == lower.viewIndex {
                let start = min(max(0, lower.charIndex), length)
                range = NSRange(location: start, length: length - start)
            } else if index == upper.viewIndex {
                let end = min(max(0, upper.charIndex), length)
                range = NSRange(location: 0, length: end)
            } else {
                range = NSRange(location: 0, length: length)
            }
            let targetRanges = [NSValue(range: range)]
            if view.selectedRanges != targetRanges {
                view.setSelectedRange(range)
                view.needsDisplay = true
            }
        }
    }

    fileprivate var minimumTableWidth: CGFloat {
        guard let textStorage, textStorage.length > 0,
              let info = textStorage.attribute(
                  MarkdownText.tableHeaderDividerAttribute,
                  at: 0,
                  effectiveRange: nil
              ) as? MarkdownText.TableHeaderDividerInfo else { return 0 }
        return ceil(info.tableWidth)
    }

    public func selectedCopiedText() -> String {
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else {
            return MarkdownText.copiedText(from: attributedText, in: selectedRange())
        }
        return ranges.map { MarkdownText.copiedText(from: attributedText, in: $0) }.joined(separator: "\n")
    }

    public func selectedTranscriptCopiedText() -> String {
        let peers = Self.peerSelectableTextViews(in: selectionScopeRoot)
        let selectedPeers = peers.filter(\.hasActiveSelection)
        guard !selectedPeers.isEmpty else {
            return selectedCopiedText()
        }
        if selectedPeers.count == 1, let only = selectedPeers.first {
            return only.selectedCopiedText()
        }
        return selectedPeers
            .map { $0.selectedCopiedText() }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public func headerDividerY() -> CGFloat? {
        guard let textStorage,
              let layoutManager,
              let textContainer,
              textStorage.length > 0,
              let info = textStorage.attribute(
                  MarkdownText.tableHeaderDividerAttribute,
                  at: 0,
                  effectiveRange: nil
              ) as? MarkdownText.TableHeaderDividerInfo,
              info.firstBodyRowCharacterIndex > 0,
              info.firstBodyRowCharacterIndex < textStorage.length else { return nil }
        let bodyCharRange = NSRange(location: info.firstBodyRowCharacterIndex, length: 1)
        let bodyGlyphRange = layoutManager.glyphRange(
            forCharacterRange: bodyCharRange,
            actualCharacterRange: nil
        )
        let bodyRect = layoutManager.boundingRect(
            forGlyphRange: bodyGlyphRange,
            in: textContainer
        )
        guard bodyRect.minY.isFinite, bodyRect.minY > 6 else { return nil }
        return bodyRect.minY - 6
    }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return Self.peerSelectableTextViews(in: selectionScopeRoot).contains(where: \.hasActiveSelection)
        }
        return super.validateUserInterfaceItem(item)
    }

    public override func copy(_ sender: Any?) {
        let peers = Self.peerSelectableTextViews(in: selectionScopeRoot)
        let selectedPeers = peers.filter(\.hasActiveSelection)
        if selectedPeers.count > 1 || (selectedPeers.count == 1 && selectedPeers.first !== self) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(selectedTranscriptCopiedText(), forType: .string)
            return
        }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.contains(where: { MarkdownText.tableCopiedText(from: attributedText, in: $0) != nil }) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(selectedCopiedText(), forType: .string)
        } else {
            super.copy(sender)
        }
    }

    private func clearPeerSelectionsExcludingSelf() {
        for peer in Self.peerSelectableTextViews(in: selectionScopeRoot) where peer !== self && peer.hasActiveSelection {
            peer.setSelectedRange(NSRange(location: 0, length: 0))
            peer.needsDisplay = true
        }
    }

    private func clearSelectionInScope() {
        let scope = selectionScopeRoot
        clearPeerSelectionsExcludingSelf()
        if hasActiveSelection {
            setSelectedRange(NSRange(location: 0, length: 0))
            needsDisplay = true
        }
        if Self.lastSelectionAnchor?.scopeRoot == nil || Self.lastSelectionAnchor?.scopeRoot === scope {
            Self.lastSelectionAnchor = nil
        }
    }

    public override func selectAll(_ sender: Any?) {
        clearPeerSelectionsExcludingSelf()
        super.selectAll(sender)
        Self.lastSelectionAnchor = SelectionAnchor(
            scopeRoot: selectionScopeRoot,
            view: self,
            range: selectedRange()
        )
    }

    public override func doCommand(by selector: Selector) {
        let beforeRanges = selectedRanges
        let name = NSStringFromSelector(selector)
        let isSelectionCommand = name.hasPrefix("move")
            || name.hasPrefix("select")
            || name.hasPrefix("cancel")
        super.doCommand(by: selector)
        if isSelectionCommand || selectedRanges != beforeRanges {
            clearPeerSelectionsExcludingSelf()
            Self.lastSelectionAnchor = SelectionAnchor(
                scopeRoot: selectionScopeRoot,
                view: self,
                range: selectedRange()
            )
        }
    }

    private func autoscrollEnclosingScrollViews(with event: NSEvent) {
        var current: NSView? = superview
        while let view = current {
            if let clipView = view as? NSClipView {
                clipView.autoscroll(with: event)
            }
            current = view.superview
        }
    }

    private func linkTarget(at localPoint: NSPoint) -> (url: Any, charIndex: Int)? {
        guard let textStorage,
              let layoutManager,
              let textContainer,
              textStorage.length > 0 else {
            return nil
        }
        layoutManager.ensureLayout(for: textContainer)
        let containerPoint = NSPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < textStorage.length,
              let linkValue = textStorage.attribute(.link, at: charIndex, effectiveRange: nil) else {
            return nil
        }
        return (linkValue, charIndex)
    }

    public override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        if event.modifierFlags.contains(.control) {
            let previousPreserving = Self.isPreservingCrossViewSelection
            Self.isPreservingCrossViewSelection = true
            defer { Self.isPreservingCrossViewSelection = previousPreserving }
            super.mouseDown(with: event)
            return
        }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            clearPeerSelectionsExcludingSelf()
            super.mouseDown(with: event)
            Self.lastSelectionAnchor = SelectionAnchor(
                scopeRoot: selectionScopeRoot,
                view: self,
                range: selectedRange()
            )
            return
        }
        if let textContainer {
            layoutManager?.ensureLayout(for: textContainer)
        }
        let scopeRoot = selectionScopeRoot
        let initialWindowPoint = event.locationInWindow
        let initialLocalPoint = convert(initialWindowPoint, from: nil)
        let clickedCharIndex = min(
            max(0, characterIndexForInsertion(at: initialLocalPoint)),
            attributedText.length
        )
        let granularity: NSSelectionGranularity = switch event.clickCount {
        case 2: .selectByWord
        case let count where count >= 3: .selectByParagraph
        default: .selectByCharacter
        }

        if granularity == .selectByCharacter,
           !event.modifierFlags.contains(.shift),
           Self.peerSelectableTextViews(in: scopeRoot).filter(\.hasActiveSelection) == [self],
           selectedRanges.map(\.rangeValue).contains(where: { $0.length > 0 && NSLocationInRange(clickedCharIndex, $0) }) {
            super.mouseDown(with: event)
            if !hasActiveSelection {
                Self.lastSelectionAnchor = SelectionAnchor(
                    scopeRoot: selectionScopeRoot,
                    view: self,
                    range: selectedRange()
                )
            }
            return
        }

        let anchor: SelectionAnchor
        if event.modifierFlags.contains(.shift),
           let existing = Self.lastSelectionAnchor,
           existing.scopeRoot === scopeRoot,
           let existingView = existing.view,
           Self.peerSelectableTextViews(in: scopeRoot).contains(where: { $0 === existingView }) {
            anchor = existing
        } else {
            let resolvedRange = resolvedAnchorRange(at: clickedCharIndex, granularity: granularity)
            anchor = SelectionAnchor(
                scopeRoot: scopeRoot,
                view: self,
                range: resolvedRange
            )
            Self.lastSelectionAnchor = anchor
        }

        if window.firstResponder !== self {
            Self.isPreservingCrossViewSelection = true
            window.makeFirstResponder(self)
            Self.isPreservingCrossViewSelection = false
        }

        if event.modifierFlags.contains(.shift) || granularity != .selectByCharacter {
            let pointInRoot = scopeRoot.convert(initialWindowPoint, from: nil)
            Self.updateCrossViewSelection(
                anchor: anchor,
                pointInRoot: pointInRoot,
                granularity: granularity,
                in: scopeRoot
            )
        } else {
            clearSelectionInScope()
            Self.lastSelectionAnchor = anchor
            setSelectedRange(NSRange(location: clickedCharIndex, length: 0))
        }

        var lastDragEvent = event
        var didDrag = false
        let dragThreshold: CGFloat = 2
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }

        while let nextEvent = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .periodic],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            switch nextEvent.type {
            case .leftMouseDragged:
                lastDragEvent = nextEvent
                let windowPoint = nextEvent.locationInWindow
                if !didDrag,
                   hypot(windowPoint.x - initialWindowPoint.x, windowPoint.y - initialWindowPoint.y) >= dragThreshold {
                    didDrag = true
                }
                if didDrag || granularity != .selectByCharacter {
                    autoscrollEnclosingScrollViews(with: nextEvent)
                    let currentScopeRoot = selectionScopeRoot
                    let pointInRoot = currentScopeRoot.convert(windowPoint, from: nil)
                    Self.updateCrossViewSelection(
                        anchor: anchor,
                        pointInRoot: pointInRoot,
                        granularity: granularity,
                        in: currentScopeRoot
                    )
                }
            case .periodic:
                if didDrag {
                    autoscrollEnclosingScrollViews(with: lastDragEvent)
                    let windowPoint = window.mouseLocationOutsideOfEventStream
                    let currentScopeRoot = selectionScopeRoot
                    let pointInRoot = currentScopeRoot.convert(windowPoint, from: nil)
                    Self.updateCrossViewSelection(
                        anchor: anchor,
                        pointInRoot: pointInRoot,
                        granularity: granularity,
                        in: currentScopeRoot
                    )
                }
            case .leftMouseUp:
                let windowPoint = nextEvent.locationInWindow
                if !didDrag,
                   hypot(windowPoint.x - initialWindowPoint.x, windowPoint.y - initialWindowPoint.y) >= dragThreshold {
                    didDrag = true
                }
                if didDrag {
                    autoscrollEnclosingScrollViews(with: nextEvent)
                    let currentScopeRoot = selectionScopeRoot
                    let pointInRoot = currentScopeRoot.convert(windowPoint, from: nil)
                    Self.updateCrossViewSelection(
                        anchor: anchor,
                        pointInRoot: pointInRoot,
                        granularity: granularity,
                        in: currentScopeRoot
                    )
                } else if granularity == .selectByCharacter, !event.modifierFlags.contains(.shift) {
                    if let (link, charIndex) = linkTarget(at: initialLocalPoint) {
                        clicked(onLink: link, at: charIndex)
                    }
                }
                return
            default:
                break
            }
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let scope = selectionScopeRoot
        let peers = Self.peerSelectableTextViews(in: scope)
        let savedSelections = peers.map { ($0, $0.selectedRanges) }
        let hadSelectionOnSelf = hasActiveSelection
        let previousPreserving = Self.isPreservingCrossViewSelection
        Self.isPreservingCrossViewSelection = true
        defer { Self.isPreservingCrossViewSelection = previousPreserving }
        if !hadSelectionOnSelf {
            clearPeerSelectionsExcludingSelf()
        }
        let result = super.menu(for: event)
        if hadSelectionOnSelf {
            for (peer, ranges) in savedSelections where peer.selectedRanges != ranges {
                peer.selectedRanges = ranges
                peer.needsDisplay = true
            }
        }
        return result
    }

    public override var intrinsicContentSize: NSSize {
        let targetWidth = wrapsText && preferredMaxLayoutWidth > 0
            ? preferredMaxLayoutWidth
            : CGFloat.greatestFiniteMagnitude
        return measuredSize(forWidth: targetWidth)
    }

    func measuredSize(forWidth width: CGFloat) -> CGSize {
        guard let textContainer, let layoutManager else { return .zero }
        textContainer.lineFragmentPadding = 0
        let finiteWidth = wrapsText && width.isFinite && width > 0
            && width < CGFloat.greatestFiniteMagnitude
        let naturalWidth: CGFloat
        if finiteWidth {
            naturalWidth = width
        } else {
            let bounded = attributedText.boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).width
            naturalWidth = max(ceil(bounded), minimumTableWidth)
        }
        textContainer.widthTracksTextView = false
        textContainer.size = CGSize(
            width: max(1, naturalWidth),
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(
            width: naturalWidth,
            height: ceil(used.height)
        )
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0, let textContainer {
            let containerWidth = wrapsText
                ? newSize.width
                : max(newSize.width, minimumTableWidth)
            textContainer.size = CGSize(
                width: containerWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textStorage,
              let layoutManager,
              let textContainer,
              textStorage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(
            MarkdownText.quoteBarAttribute,
            in: fullRange
        ) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            guard rect.height > 0 else { return }
            let barX = userInterfaceLayoutDirection == .rightToLeft
                ? bounds.maxX - 3
                : 0
            let barRect = NSRect(
                x: barX,
                y: rect.minY,
                width: 3,
                height: rect.height
            )
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()
        }
        if let dividerY = headerDividerY() {
            let lineRect = NSRect(
                x: 0,
                y: dividerY,
                width: max(bounds.width, minimumTableWidth),
                height: 1
            )
            NSColor.separatorColor.setFill()
            lineRect.fill()
        }
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        guard resigned, !Self.isPreservingCrossViewSelection else {
            return resigned
        }
        let scope = selectionScopeRoot
        clearSelectionInScope()
        if Self.lastSelectionAnchor?.scopeRoot == nil || Self.lastSelectionAnchor?.scopeRoot === scope {
            Self.lastSelectionAnchor = nil
        }
        return resigned
    }
}

private struct SelectableMarkdownText: NSViewRepresentable {
    let wraps: Bool
    let segment: MarkdownText.RenderSegment

    private func renderKey(context: Context) -> MarkdownText.RenderKey {
        MarkdownText.RenderKey(
            segment: segment,
            styleContext: MarkdownText.StyleContext(
                dynamicTypeSize: context.environment.dynamicTypeSize,
                legibilityWeight: context.environment.legibilityWeight
            ),
            layoutDirection: context.environment.layoutDirection
        )
    }

    func makeNSView(context: Context) -> MarkdownSelectableTextView {
        let key = renderKey(context: context)
        let attributedText = MarkdownText.makeSegmentAttributedText(key)
        let textView = MarkdownSelectableTextView(frame: .zero)
        textView.renderKey = key
        textView.wrapsText = wraps
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(
            wraps ? .defaultLow : .required,
            for: .horizontal
        )
        textView.attributedText = attributedText
        textView.setAccessibilityLabel(MarkdownText.accessibilityText(for: attributedText))
        return textView
    }

    func updateNSView(_ nsView: MarkdownSelectableTextView, context: Context) {
        let key = renderKey(context: context)
        nsView.wrapsText = wraps
        nsView.isHorizontallyResizable = !wraps
        nsView.textContainer?.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        guard nsView.renderKey != key else { return }
        nsView.renderKey = key
        let attributedText = MarkdownText.makeSegmentAttributedText(key)
        if nsView.attributedText != attributedText {
            let previousRanges = nsView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
            let previousString = nsView.attributedText.string as NSString
            let nextString = attributedText.string as NSString
            nsView.attributedText = attributedText
            nsView.setAccessibilityLabel(MarkdownText.accessibilityText(for: attributedText))
            if !previousRanges.isEmpty,
               previousRanges.allSatisfy({
                   NSMaxRange($0) <= nextString.length
                       && previousString.substring(with: $0) == nextString.substring(with: $0)
               }) {
                nsView.selectedRanges = previousRanges.map(NSValue.init(range:))
            } else if nsView.selectedRanges.contains(where: { $0.rangeValue.location != 0 || $0.rangeValue.length != 0 }) {
                nsView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            nsView.invalidateIntrinsicContentSize()
            nsView.needsDisplay = true
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MarkdownSelectableTextView,
        context: Context
    ) -> CGSize? {
        if wraps {
            if let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0 {
                nsView.preferredMaxLayoutWidth = proposedWidth
                return nsView.measuredSize(forWidth: proposedWidth)
            }
            let fallbackWidth = nsView.preferredMaxLayoutWidth > 0
                ? nsView.preferredMaxLayoutWidth
                : CGFloat.greatestFiniteMagnitude
            let measured = nsView.measuredSize(forWidth: fallbackWidth)
            return CGSize(
                width: nsView.preferredMaxLayoutWidth > 0 ? fallbackWidth : measured.width,
                height: measured.height
            )
        } else {
            return nsView.measuredSize(forWidth: CGFloat.greatestFiniteMagnitude)
        }
    }
}
#endif

#endif
