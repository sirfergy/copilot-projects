import Foundation
import SwiftTerm
import CopilotProjectsProtocol
import ImageIO
import UniformTypeIdentifiers

// MARK: - Bounds

/// A single unterminated APC frame (control data + one chunk's payload) is
/// bounded well past the ~4 KiB raw chunks real encoders emit, so a runaway
/// non-terminated sequence can't grow memory unbounded.
private let remoteKittyMaxRawFrameBytes = 96 * 1_024
/// Base64 accumulated across `m=1` continuation chunks for a single in-flight
/// image, bounded comfortably above the base64 size of `remoteKittyMaxDecodedImageBytes`.
private let remoteKittyMaxAccumulatedBase64Bytes = 8 * 1_024 * 1_024
/// Decoded PNG bytes retained per image.
private let remoteKittyMaxDecodedImageBytes = 5 * 1_024 * 1_024
private let remoteKittyMaxImageDimension = 4_096
private let remoteKittyMaxImagePixels = 16_000_000
/// Total bytes retained per-*session* (per `RemoteKittyImageCapture` instance)
/// across all its (id, version) entries in the grace cache. Deliberately much
/// smaller than `RemoteKittyImageCaptureBudget`'s process-wide bound below —
/// this only guards a single busy terminal, while the shared budget guards the
/// whole process across every open terminal.
private let remoteKittyMaxTotalRetainedBytes = 8 * 1_024 * 1_024
/// Entry count cap for the per-session grace cache (independent of the byte
/// cap, so a burst of tiny images can't accumulate unboundedly either), also
/// deliberately smaller than the process-wide entry cap.
private let remoteKittyMaxRetainedEntries = 16
/// Hard cap on the combined `exactActivePlacements` + `deletedPlacements`
/// entry count tracked by `RemoteKittyImageCapture`, independent of
/// `wildcardActiveImageIds` (already bounded by the number of distinct
/// still-retained image ids, itself capped by `remoteKittyMaxRetainedEntries`
/// above). Without this, a *single* retained image id could still drive
/// either set unboundedly large on its own — many distinct placement ids via
/// repeated `a=p,p=<n>` (each a fresh `exactActivePlacements` entry) or, once
/// wildcard-active, many scoped `d=i,i=<id>,p=<n>` deletes (each a fresh
/// `deletedPlacements` exception) — neither of which allocates any new
/// retained bytes/entries the bounds above already guard against. Small and
/// deterministic: comfortably above any real client's legitimate placement
/// count per image, but never allowed to grow past it regardless of churn.
private let remoteKittyMaxPlacementActivityEntries = 256
/// Size above which a discarded/finalized transient buffer (`rawFrame` or
/// `pendingBase64`) has its underlying storage actually deallocated
/// (`keepingCapacity: false`) rather than kept around for reuse. Below this,
/// `keepingCapacity: true` avoids paying for a realloc on every tiny/common
/// frame. A buffer that grew past this before being discarded proves it can
/// grow large, so its capacity must be given back — otherwise N busy
/// terminals could each pin megabytes of buffer capacity even though the
/// shared pending-byte *count* budget below is enforced.
private let remoteKittyLargeBufferReleaseThreshold = 64 * 1_024
/// Hard cap on placements emitted by a single scan, so a pathological grid
/// (e.g. hundreds of disjoint single-cell placeholder fragments) can't make a
/// scan (or its JSON payload) unbounded. Connected-component work stops the
/// moment this many placements have been found, rather than discovering every
/// component and truncating only the final list.
private let remoteKittyMaxEmittedPlacements = 64

// MARK: - Placeholder grapheme decoding (pure, SwiftTerm-independent)

/// Decodes the Kitty Unicode-placeholder scheme (`U+10EEEE` + foreground color
/// carrying the low 24 bits of the image id) directly from plain grapheme +
/// color inputs, so this logic is testable without any SwiftTerm dependency and
/// matches the Kitty protocol and SwiftTerm's
/// `KittyPlaceholderDecoder.colorToId` byte order:
/// `(red << 16) | (green << 8) | blue`.
enum RemoteKittyPlaceholderCell {
    static let baseScalar: UInt32 = 0x10EEEE

    /// Returns the low-24-bit image id encoded in `character`'s foreground color,
    /// or `nil` if `character` isn't a standard placeholder grapheme (first
    /// scalar isn't `U+10EEEE`) or its foreground isn't a truecolor value, or the
    /// decoded id is out of the `1...0xFFFFFF` range our capture ever assigns.
    static func decodeImageId(
        character: Character,
        foreground: (red: UInt8, green: UInt8, blue: UInt8)?
    ) -> UInt32? {
        guard let foreground else { return nil }
        guard let first = character.unicodeScalars.first, first.value == baseScalar else {
            return nil
        }
        let imageId = (UInt32(foreground.red) << 16)
            | (UInt32(foreground.green) << 8)
            | UInt32(foreground.blue)
        guard imageId >= 1, imageId <= 0xFFFFFF else { return nil }
        return imageId
    }

    /// Decodes the low-24-bit placement id encoded in a cell's *underline*
    /// color, using the exact same byte order as `decodeImageId`'s
    /// foreground decode (`red << 16 | green << 8 | blue`) — mirroring
    /// SwiftTerm's own (private) `KittyPlaceholderDecoder.colorToId` applied
    /// to `Attribute.underlineColor` instead of `.fg`. Unlike `decodeImageId`,
    /// this never fails: a cell with no truecolor underline set at all (the
    /// common case — a client that never sent an explicit `p=`) decodes to
    /// `0`, the Kitty spec's implicit default placement, not `nil`.
    static func decodePlacementId(underline: (red: UInt8, green: UInt8, blue: UInt8)?) -> UInt32 {
        guard let underline else { return 0 }
        return (UInt32(underline.red) << 16)
            | (UInt32(underline.green) << 8)
            | UInt32(underline.blue)
    }
}

/// Text-level sanitization shared by both live and history line capture: a raw
/// placeholder grapheme is meaningless (and potentially confusing) as remote
/// text, so it collapses to a single space, preserving the cell/column count.
enum RemoteKittyGraphics {
    static func sanitizeLine(_ line: String) -> String {
        guard line.unicodeScalars.contains(where: { $0.value == RemoteKittyPlaceholderCell.baseScalar }) else {
            return line
        }
        var result = ""
        result.reserveCapacity(line.count)
        for character in line {
            if character.unicodeScalars.first?.value == RemoteKittyPlaceholderCell.baseScalar {
                result.append(" ")
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// Structural (never full-bitmap) PNG validation, shared by every path that
/// must trust bytes it didn't just decode itself: the live capture path
/// (`RemoteKittyImageCapture.finalizePending`, decoding a fresh base64
/// payload) and the durable disk-persistence path (`RemoteKittyImageDiskStore`,
/// which must revalidate every byte it reads back from disk on restore —
/// on-disk corruption/truncation is untrusted input exactly like a live
/// transmission's payload, never assumed safe just because this process wrote
/// it in an earlier run). ImageIO only parses the PNG container's
/// chunks/metadata here (`CGImageSourceGetStatusAtIndex`), never
/// decoding/allocating the full pixel bitmap, so this stays cheap even for a
/// large image.
enum RemoteKittyPNGValidation {
    static func isStructurallyValid(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), type as String == UTType.png.identifier,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        guard width > 0, height > 0,
              width <= remoteKittyMaxImageDimension,
              height <= remoteKittyMaxImageDimension
        else { return false }
        guard width * height <= remoteKittyMaxImagePixels else { return false }
        return true
    }
}

/// Builds the exact normalized Kitty APC byte sequences a restored image is
/// replayed with (see `ProjectsTerminalView.replayRestoredImage`): a
/// response-suppressed (`q=2`), transmit-only (`a=t`) chunked transmission of
/// the exact retained PNG bytes — never activating a placement on its own —
/// followed by a response-suppressed re-placement (`a=p,U=1,q=2`) naming the
/// *exact* placement id the original live capture activated. Pure/static so
/// the exact byte layout is unit-testable without a live `Terminal`, and
/// shared so production replay and its tests can never drift from each other.
enum RemoteKittyReplayEncoding {
    /// Base64 characters per `a=t` continuation frame — comfortably under
    /// `remoteKittyMaxRawFrameBytes`, mirroring how a real client chunks a
    /// large image across `m=1` continuations rather than risking one
    /// oversized APC frame.
    static let chunkBytes = 32 * 1_024

    /// One 7-bit APC Kitty graphics frame: `ESC _ G <control>[;<payload>] ESC \`.
    static func apcFrame(control: String, payload: String = "") -> [UInt8] {
        var bytes: [UInt8] = [0x1B, 0x5F, 0x47] // ESC _ G
        bytes.append(contentsOf: Array(control.utf8))
        if !payload.isEmpty {
            bytes.append(0x3B) // ';'
            bytes.append(contentsOf: Array(payload.utf8))
        }
        bytes.append(contentsOf: [0x1B, 0x5C]) // ESC \ (ST)
        return bytes
    }

    /// Transmit-only (`a=t`), response-suppressed (`q=2`) frame(s) carrying
    /// `data`'s exact base64 bytes, chunked via `m=1`/`m=0` continuations
    /// exactly like a real large upload — never `a=T`, so this alone never
    /// activates any placement (matching a restore's "images first, then
    /// placement" replay ordering).
    static func transmitOnlyFrames(imageId: UInt32, data: Data) -> [UInt8] {
        let base64 = data.base64EncodedString()
        var pieces: [Substring] = []
        var remaining = Substring(base64)
        while !remaining.isEmpty {
            let end = remaining.index(
                remaining.startIndex, offsetBy: chunkBytes, limitedBy: remaining.endIndex
            ) ?? remaining.endIndex
            pieces.append(remaining[..<end])
            remaining = remaining[end...]
        }
        if pieces.isEmpty { pieces = [""] }
        var bytes: [UInt8] = []
        for (index, piece) in pieces.enumerated() {
            let more = index != pieces.count - 1
            if index == 0 {
                bytes += apcFrame(
                    control: "a=t,q=2,U=1,f=100,t=d,i=\(imageId),m=\(more ? 1 : 0)",
                    payload: String(piece)
                )
            } else {
                bytes += apcFrame(control: "m=\(more ? 1 : 0)", payload: String(piece))
            }
        }
        return bytes
    }

    /// A response-suppressed (`q=2`) `a=p,U=1` re-placement naming the exact
    /// positive `placementId` (never omitted — SwiftTerm treats `p=0` as
    /// unset and mints a fresh auto-incremented id on every replay) with the
    /// exact preserved `c=`/`r=` cell-span and optional `X=`/`Y=`/`z=`
    /// pixel-offset/z-index metadata a real combined `a=T` transmission
    /// carried.
    static func placementFrame(
        imageId: UInt32,
        placementId: UInt32,
        rows: Int,
        columns: Int,
        x: Int? = nil,
        y: Int? = nil,
        z: Int? = nil
    ) -> [UInt8] {
        var control = "a=p,U=1,q=2,i=\(imageId),p=\(placementId),r=\(rows),c=\(columns)"
        if let x { control += ",X=\(x)" }
        if let y { control += ",Y=\(y)" }
        if let z { control += ",z=\(z)" }
        return apcFrame(control: control)
    }
}

// MARK: - Grid scanning -> placements (pure, SwiftTerm-independent)

/// One decoded placeholder grid cell, in the coordinate space the caller used
/// (viewport row ids for a live screen, scroll-invariant absolute row ids for a
/// history screen).
struct RemoteKittyGridCell: Equatable {
    let lineId: Int
    let col: Int
    let imageId: UInt32
    /// The placement id decoded from this cell's underline color (`0` when
    /// no explicit `p=` was ever encoded — the Kitty spec's implicit default
    /// placement). Defaulted so every existing call site that never cared
    /// about multiple placements per image id keeps compiling unchanged.
    let placementId: UInt32

    init(lineId: Int, col: Int, imageId: UInt32, placementId: UInt32 = 0) {
        self.lineId = lineId
        self.col = col
        self.imageId = imageId
        self.placementId = placementId
    }
}

enum RemoteKittyPlacementScanner {
    private struct Coordinate: Hashable {
        let lineId: Int
        let col: Int
    }

    /// Groups cells by *both* image id and placement id — never image id
    /// alone — so two distinct placements of the same image id (e.g. one
    /// deleted via a scoped `d=i,i=X,p=Y`, the other still showing) are
    /// always kept as separate components/groups, even when spatially
    /// adjacent or overlapping, and are looked up independently against the
    /// capture's per-placement activity state.
    private struct GroupKey: Hashable {
        let imageId: UInt32
        let placementId: UInt32
    }

    /// One fully flood-filled connected component, still tagged with its
    /// bounding box in the caller's line-id coordinate space (not yet
    /// translated relative to `firstLine`) so priority classification and
    /// bottom-first sorting can both work directly off `minLine`.
    private struct Component {
        let imageId: UInt32
        let placementId: UInt32
        let version: UInt64
        let minLine: Int
        let maxLine: Int
        let minCol: Int
        let maxCol: Int
    }

    /// Groups `cells` by `(imageId, placementId)`, splits each group's cells
    /// into 4-neighbor connected components (so two disjoint placements —
    /// whether they share an image id and differ only by placement id, or
    /// are simply spatially disjoint — never merge into one bounding box),
    /// and emits one placement per component — only for groups with a
    /// `currentVersion`, i.e. a still-retained-and-active capture for that
    /// exact `(imageId, placementId)` pair. `firstLine` converts the
    /// caller's absolute/viewport line ids into rows relative to the emitted
    /// screen. Sorted deterministically by (line, column, imageId) so
    /// repeated scans of the same grid are stable.
    ///
    /// Emits at most `remoteKittyMaxEmittedPlacements` placements, chosen in
    /// two priority tiers so a producer scanning the *entire* retained
    /// history can never let old/stale history starve the current/new
    /// content a client actually asked for:
    ///
    /// 1. Every component that intersects `priorityLineRange` (any one of its
    ///    cells has a `lineId` inside that range) — i.e. the screen window a
    ///    client is actually looking at right now (the whole viewport for a
    ///    live scan, or just the emitted incremental text window for a
    ///    history scan). These are always considered first, sorted
    ///    deterministically ascending by `(minLine, minCol, imageId)`, and
    ///    truncated to the cap if even this tier alone exceeds it.
    /// 2. Whatever cap budget remains (if any) is spent on every other,
    ///    non-intersecting component — the rest of the retained history —
    ///    sorted deterministically newest/bottom-first (descending
    ///    `minLine`, since a larger scroll-invariant row id is always more
    ///    recent), so among old history that doesn't fit, the *most* recent
    ///    of it is kept over the oldest.
    ///
    /// Either way a component is always emitted whole or not at all — the
    /// cap only ever drops entire components, never truncates one — and the
    /// final returned order is always the same (line, column, imageId) sort
    /// regardless of which tier a placement was selected from.
    static func scan(
        cells: [RemoteKittyGridCell],
        firstLine: Int,
        priorityLineRange: Range<Int>,
        currentVersion: (UInt32, UInt32) -> UInt64?
    ) -> [RemoteTerminalImagePlacement] {
        guard !cells.isEmpty else { return [] }

        var byGroup: [GroupKey: Set<Coordinate>] = [:]
        for cell in cells {
            let key = GroupKey(imageId: cell.imageId, placementId: cell.placementId)
            byGroup[key, default: []].insert(Coordinate(lineId: cell.lineId, col: cell.col))
        }

        var priorityComponents: [Component] = []
        var otherComponents: [Component] = []

        let sortedGroups = byGroup.keys.sorted {
            if $0.imageId != $1.imageId { return $0.imageId < $1.imageId }
            return $0.placementId < $1.placementId
        }
        for group in sortedGroups {
            guard let version = currentVersion(group.imageId, group.placementId),
                  let coordinates = byGroup[group] else { continue }
            // Seeded deterministically (smallest `(lineId, col)` first) —
            // sorted once per group up front, rather than repeatedly
            // scanning the shrinking `remaining` set for its minimum before
            // every single component. That repeated-`.min()` approach made
            // discovery cost O(component count) *per component*, which for a
            // checkerboard grid (every marked cell its own disjoint
            // single-cell component, so component count == cell count) is
            // O(n^2) in total cells for that group. Sorting once is
            // O(n log n); `remaining` still gives O(1) flood-fill
            // neighbor membership/removal, and each sorted seed is visited or
            // skipped (already claimed by an earlier component) exactly
            // once, so the whole seed walk is O(n) on top of the sort.
            // Component membership, priority-tier classification, and the
            // final deterministic sort/cap below are all unchanged — the
            // *set* of coordinates flood-filled into each component never
            // depends on which of its members was chosen as the seed.
            var remaining = coordinates
            let sortedSeeds = coordinates.sorted { ($0.lineId, $0.col) < ($1.lineId, $1.col) }
            for start in sortedSeeds {
                guard remaining.contains(start) else { continue }
                remaining.remove(start)
                var component: [Coordinate] = [start]
                var frontier = [start]
                var intersectsPriority = priorityLineRange.contains(start.lineId)
                while let coordinate = frontier.popLast() {
                    let neighbors = [
                        Coordinate(lineId: coordinate.lineId - 1, col: coordinate.col),
                        Coordinate(lineId: coordinate.lineId + 1, col: coordinate.col),
                        Coordinate(lineId: coordinate.lineId, col: coordinate.col - 1),
                        Coordinate(lineId: coordinate.lineId, col: coordinate.col + 1),
                    ]
                    for neighbor in neighbors where remaining.contains(neighbor) {
                        remaining.remove(neighbor)
                        component.append(neighbor)
                        frontier.append(neighbor)
                        if priorityLineRange.contains(neighbor.lineId) { intersectsPriority = true }
                    }
                }
                let lineIds = component.map(\.lineId)
                let cols = component.map(\.col)
                guard let minLine = lineIds.min(), let maxLine = lineIds.max(),
                      let minCol = cols.min(), let maxCol = cols.max() else { continue }
                let entry = Component(
                    imageId: group.imageId, placementId: group.placementId, version: version,
                    minLine: minLine, maxLine: maxLine, minCol: minCol, maxCol: maxCol
                )
                if intersectsPriority {
                    priorityComponents.append(entry)
                } else {
                    otherComponents.append(entry)
                }
            }
        }

        priorityComponents.sort {
            if $0.minLine != $1.minLine { return $0.minLine < $1.minLine }
            if $0.minCol != $1.minCol { return $0.minCol < $1.minCol }
            if $0.imageId != $1.imageId { return $0.imageId < $1.imageId }
            return $0.placementId < $1.placementId
        }
        otherComponents.sort {
            if $0.minLine != $1.minLine { return $0.minLine > $1.minLine }
            if $0.minCol != $1.minCol { return $0.minCol < $1.minCol }
            if $0.imageId != $1.imageId { return $0.imageId < $1.imageId }
            return $0.placementId < $1.placementId
        }

        var selected = Array(priorityComponents.prefix(remoteKittyMaxEmittedPlacements))
        let remainingBudget = remoteKittyMaxEmittedPlacements - selected.count
        if remainingBudget > 0 {
            selected.append(contentsOf: otherComponents.prefix(remainingBudget))
        }

        let placements = selected.map {
            RemoteTerminalImagePlacement(
                imageId: $0.imageId,
                contentVersion: $0.version,
                line: $0.minLine - firstLine,
                column: $0.minCol,
                rows: $0.maxLine - $0.minLine + 1,
                columns: $0.maxCol - $0.minCol + 1
            )
        }
        return placements.sorted {
            if $0.line != $1.line { return $0.line < $1.line }
            if $0.column != $1.column { return $0.column < $1.column }
            return $0.imageId < $1.imageId
        }
    }

    /// Reads only copied cell text and attributes. `relativeTo` converts
    /// absolute snapshot rows to viewport rows for a live screen.
    static func gridCells(
        from lines: [TerminalContentRowSnapshot],
        relativeTo: Int = 0
    ) -> [RemoteKittyGridCell] {
        var cells: [RemoteKittyGridCell] = []
        for line in lines {
            for (col, cell) in line.cells.enumerated() {
                guard case .trueColor(let red, let green, let blue) = cell.attribute.fg,
                      let character = cell.text.first,
                      let imageId = RemoteKittyPlaceholderCell.decodeImageId(
                        character: character,
                        foreground: (red, green, blue)
                      ) else { continue }
                let underline: (red: UInt8, green: UInt8, blue: UInt8)?
                if case .trueColor(let ur, let ug, let ub) = cell.attribute.underlineColor {
                    underline = (ur, ug, ub)
                } else {
                    underline = nil
                }
                let placementId = RemoteKittyPlaceholderCell.decodePlacementId(underline: underline)
                cells.append(RemoteKittyGridCell(
                    lineId: line.absoluteRow - relativeTo, col: col,
                    imageId: imageId, placementId: placementId))
            }
        }
        return cells
    }
}

// MARK: - Kitty graphics APC capture (bounded, fail-closed)

/// Captures the exact Copilot Kitty graphics subset (7-bit APC
/// `ESC _ G ... ESC \`, direct transmission, `f=100` PNG, `U=1`, explicit
/// 1-in-0xFFFFFF image ids, `m=1` continuation chunks) from raw terminal output
/// bytes, independent of SwiftTerm's own (private, display-only) Kitty state.
///
/// One instance is owned per terminal session (`ProjectsTerminalView`) — never a
/// shared/global identity-bearing store — and every mutating access happens on
/// the main actor, serialized with this host's parser feeds. Rendering consumes
/// SwiftTerm's own copied state independently. Retained bytes are
/// additionally accounted against a process-wide `RemoteKittyImageCaptureBudget`
/// (also main-actor-only), so no fixed number of open terminals can be relied
/// upon to keep total memory bounded — the shared budget enforces that across
/// every instance regardless of how many terminals are open.
///
/// Anything outside the supported subset (unsupported compression/transmission
/// medium/format/id, malformed or oversized frames) is silently ignored: the
/// capture never throws, never grows without bound, and a later well-formed
/// frame always parses correctly because every overflow discards and
/// resynchronizes rather than wedging the scanner's state.
///
/// Every other terminal string type that can carry its own `ESC` bytes — OSC
/// (`ESC ]`), DCS (`ESC P`), and PM (`ESC ^`) — is also tracked (its payload
/// entirely ignored) up to its own real terminator (BEL or ST for OSC, ST
/// only for DCS/PM), so a `ESC _ G` byte sequence that merely happens to
/// appear *inside* one of their payloads (e.g. inside base64-ish OSC title
/// data) can never be misparsed as the start of our own Kitty APC: the
/// scanner only ever looks for a fresh APC from `.ground`, never mid-string.
@MainActor
final class RemoteKittyImageCapture {
    private struct StoredKey: Hashable {
        let imageId: UInt32
        let version: UInt64
    }

    private enum ScanState {
        case ground
        case sawEsc
        case apcAwaitingMarker
        case apcAccumulating
        case apcAccumulatingEsc
        case apcSkipping
        case apcSkippingEsc
        /// Inside an OSC (`ESC ]`), DCS (`ESC P`), or PM (`ESC ^`) string
        /// whose payload is being ignored outright — never parsed as our own
        /// Kitty subset, and never able to nest one. `allowsBEL` is true only
        /// for OSC, whose payload may additionally terminate on a bare BEL
        /// (`0x07`) rather than requiring the full ST (`ESC \`) every other
        /// string type here requires.
        case controlStringSkipping(allowsBEL: Bool)
        /// One `ESC` seen while skipping a control string: resolves to
        /// either the real ST terminator (`\`, ending the string) or, for
        /// anything else, right back into the string body — so a byte that
        /// merely happens to look like the start of our own APC (`_`) inside
        /// someone else's string payload is never treated as one.
        case controlStringSkippingEsc(allowsBEL: Bool)
    }

    private var state: ScanState = .ground
    private var rawFrame: [UInt8] = []

    private var pendingImageId: UInt32?
    private var pendingBase64: [UInt8] = []

    // Retained (id, version) entries, oldest-first; `dataByKey`/`totalBytes` are
    // kept in lockstep and `latestVersion` tracks each id's newest still-retained
    // version so a scan can tell whether an id's data is still fetchable.
    private var order: [StoredKey] = []
    private var dataByKey: [StoredKey: Data] = [:]
    private var totalBytes = 0
    private var latestVersion: [UInt32: UInt64] = [:]
    /// Wall-clock time each retained `(imageId, version)` was captured/displayed,
    /// used only to associate an image with the transcript turn active at that
    /// moment (see `retainedImageMetadata`). In-memory only and intentionally
    /// NOT persisted to the disk store: after a relaunch a restored image has no
    /// display time, so it simply isn't associated to any turn (it still renders
    /// in Terminal mode). Kept in lockstep with `dataByKey`.
    private var displayedAt: [StoredKey: Date] = [:]

    // Ids with a currently *active* Unicode-placeholder placement — tracked
    // separately from `latestVersion`/`dataByKey` (retained PNG bytes) so the
    // two lifecycles (placement vs. data) can be deleted independently, as
    // the Kitty spec itself distinguishes: a lowercase delete (`d=i`/`d=a`)
    // only ever retires a *placement*, never the underlying transmitted
    // bytes, while an uppercase one (`d=I`/`d=A`) retires both. Before this
    // separation, `currentVersion(for:)` advertised any retained id
    // regardless of whether its placement had been deleted — a ghost: a
    // client that deleted a placement (but never re-transmitted) would keep
    // seeing it in scans of the grid indefinitely, since retained bytes
    // (kept around for the grace-retention window) were the only signal.
    // An id only ever advertises via `currentVersion(for:)` when it's both
    // active *and* still has retained data.
    //
    // Placement-aware activity is tracked in three bounded sets rather than
    // one flat `Set<UInt32>` of ids, so a scoped per-placement delete
    // (`d=i,i=<id>,p=<placement>`) can hide exactly one placement of an
    // image without disturbing any of its siblings:
    //   - `wildcardActiveImageIds`: an id whose *every* placement is active
    //     except any specific one listed in `deletedPlacements` below. Set by
    //     `a=T`/`a=p` when the command omits an explicit `p=` — matching how
    //     a real client that never specifies `p=` targets "the" placement /
    //     every placement of the image alike.
    //   - `exactActivePlacements`: individual `(imageId, placementId)` pairs
    //     made active by an `a=T`/`a=p` that *did* specify an explicit `p=`.
    //   - `deletedPlacements`: exceptions overriding a wildcard-active id for
    //     one specific placement (`d=i,i=<id>,p=<placement>`), so deleting
    //     one placement never hides every other placeholder sharing the same
    //     image id.
    //
    // `wildcardActiveImageIds` is implicitly bounded by the number of
    // distinct still-retained image ids (`remoteKittyMaxRetainedEntries`),
    // but `exactActivePlacements`/`deletedPlacements` are keyed by
    // *placement* id, not image id — a single retained image id could still
    // drive either unboundedly large on its own via many distinct placement
    // ids (`a=p,p=<n>` or scoped `d=i,i=<id>,p=<n>` deletes for many `n`),
    // without ever touching the retained-id/byte counts the bound above
    // guards. `makeRoomForPlacementActivityEntry` enforces
    // `remoteKittyMaxPlacementActivityEntries` fail-closed against exactly
    // that, and `activatePlacement` avoids ever recording a redundant exact
    // entry for an id a wildcard already covers in the first place.
    private struct PlacementKey: Hashable {
        let imageId: UInt32
        let placementId: UInt32
    }
    private var wildcardActiveImageIds: Set<UInt32> = []
    private var exactActivePlacements: Set<PlacementKey> = []
    private var deletedPlacements: Set<PlacementKey> = []

    // Fixed action ("T" activates, "t" never does on its own — see
    // `retain(...)`) and optional explicit placement id (`p=`) for whichever
    // transmission is currently pending, so a chunked (`m=1`) transfer's
    // eventual `finalizePending()` still applies the *original* command's
    // activation semantics regardless of how many continuation chunks
    // (which never repeat `a=`/`p=`) came in between.
    private var pendingActivates = false
    private var pendingPlacementId: UInt32?
    /// Combined first-frame metadata a real Copilot transmission carries
    /// alongside `a=T` (e.g. `c=48,r=24`, and optionally `X=`/`Y=`/`z=`) —
    /// captured only so a later durable-disk restore can replay a faithful
    /// SwiftTerm placement (see `RemoteKittyImageDiskStore` and
    /// `RemoteKittyReplayEncoding`); never otherwise interpreted here. `nil`
    /// when the transmission never specified it (an id with no captured
    /// dimensions is simply never persisted as a restorable current
    /// selection — see `syncPersistedSelections`).
    private var pendingRows: Int?
    private var pendingColumns: Int?
    private var pendingX: Int?
    private var pendingY: Int?
    private var pendingZ: Int?

    // Content versions are `(epoch << 32) | counter`: `epoch` is fixed for this
    // instance's whole lifetime and `counter` is monotonic within it, so two
    // `RemoteKittyImageCapture` instances for the same session (e.g. the first
    // recreated after a relaunch) never hand out the same version number for
    // the same image id — a client can't have a stale cached fetch URL from
    // the old instance accidentally resolve against the new one's data.
    private let epoch: UInt32
    private var nextCounter: UInt64 = 1
    private let budget: RemoteKittyImageCaptureBudget
    private let maxAccumulatedBase64Bytes: Int

    /// This instance's owning session — the durable disk store's persistence
    /// key. Never used for any in-memory identity/lookup purpose; only to
    /// scope every disk mutation/restore to exactly this session's own data.
    let sessionId: String
    /// The durable disk store this instance's retained bytes and
    /// current-selection/placement metadata are asynchronously mirrored to,
    /// or `nil` to disable persistence entirely (every existing test
    /// constructs a capture this way, so none of them touch disk).
    private var diskStore: RemoteKittyImageDiskStore?
    /// True for the whole duration of a disk-restore replay (`beginRestoring`
    /// through `finishRestoring`) — every disk-mutating hook below becomes a
    /// no-op while this is set, so restoring previously-persisted state can
    /// never recursively re-persist it (finding: restore/replay must never
    /// double-account or re-derive fresh versions).
    private var suppressPersistToDisk = false
    /// True only between `beginRestoring()` and `finishRestoring()`, guarding
    /// `restoreEntry`/`restoreCurrentSelection` against being called outside
    /// that window (e.g. a stray call after a live session is already
    /// running).
    private var isRestoring = false
    private var restoreAdvertisedChanged = false
    // Deferred until `finishRestoring()`: registering with the (cross-session)
    // budget as each entry is restored would let it evict a sibling entry in
    // this very restore batch before `restoreCurrentSelection` has had a
    // chance to mark it current, picking eviction victims off incomplete
    // information. Registering only after every current-selection is applied
    // means eviction preference (never drop a still-current version while a
    // superseded one exists to sacrifice instead) sees this session's true
    // final state.
    private var pendingBudgetRegistrations: [StoredKey] = []

    /// Preserved per-imageId combined `a=T`/`a=t` cell-span (`c=`/`r=`) and
    /// optional pixel-offset/z-index (`X=`/`Y=`/`z=`) metadata, scoped to
    /// exactly the same "still has retained data" lifetime as
    /// `wildcardActiveImageIds`/`exactActivePlacements` (pruned in lockstep
    /// everywhere those are) — never grows with every historical id a
    /// long-lived session ever saw.
    private struct PlacementDimensions: Equatable {
        var rows: Int
        var columns: Int
        var x: Int?
        var y: Int?
        var z: Int?
    }
    private struct PlacementGeometryKey: Hashable {
        let imageId: UInt32
        let placementId: UInt32?
    }
    private var placementDimensions: [PlacementGeometryKey: PlacementDimensions] = [:]

    /// Bumped every time this instance's *currently advertised* availability
    /// for some image id can change — a fresh current version is retained, or
    /// a still-current version is removed (by local grace-cache eviction, an
    /// explicit Kitty delete/clear, or the process-wide budget reclaiming it
    /// via `evictForBudget`, including when triggered by a *different*
    /// capture instance entirely). A superseded (non-current) version being
    /// reclaimed never bumps this, since what a scan would currently discover
    /// hasn't changed. Exposed so a screen cache keyed on it (see
    /// `RemoteTerminalRevision`) invalidates itself exactly when a
    /// previously-advertised placement could now 404, including across
    /// sessions sharing the same process-wide budget.
    private(set) var imageAvailabilityGeneration: UInt64 = 0

    /// - Parameters:
    ///   - sessionId: The owning session, used only as the durable disk
    ///     store's persistence key. Defaults to a fresh random value so every
    ///     existing test call site (which never cares about persistence)
    ///     keeps compiling unchanged.
    ///   - epoch: The high 32 bits every version handed out by this instance
    ///     carries. Defaults to a fresh random value per instance (production
    ///     behavior); tests inject a fixed value for deterministic version
    ///     assertions and to prove distinct epochs never collide.
    ///   - budget: The process-wide budget this instance's retained bytes are
    ///     accounted against. Defaults to the real shared singleton; tests
    ///     inject an isolated instance so cross-test process state can never
    ///     leak into an assertion about global bounds.
    ///   - maxAccumulatedBase64Bytes: The per-instance cap on base64 bytes
    ///     accumulated across `m=1` continuation chunks for one in-flight
    ///     transmission. Defaults to the real production bound (comfortably
    ///     above `remoteKittyMaxDecodedImageBytes`'s base64 size); tests
    ///     inject a much smaller value so an overflow test can prove the
    ///     accumulated-bytes guard specifically — via many small continuation
    ///     chunks, each individually well under both the raw-frame and
    ///     decoded-image bounds — rather than relying on a single frame large
    ///     enough to *also* trip those other, unrelated bounds first.
    ///   - diskStore: The durable disk store to asynchronously mirror
    ///     retained bytes and current-selection metadata to. Defaults to
    ///     `nil` (no persistence at all) rather than the real shared
    ///     singleton, so every existing test — and any other caller that
    ///     never passes one explicitly — can never touch disk.
    init(
        sessionId: String = UUID().uuidString,
        epoch: UInt32 = UInt32.random(in: UInt32.min ... UInt32.max),
        budget: RemoteKittyImageCaptureBudget? = nil,
        maxAccumulatedBase64Bytes: Int = remoteKittyMaxAccumulatedBase64Bytes,
        diskStore: RemoteKittyImageDiskStore? = nil
    ) {
        self.sessionId = sessionId
        self.epoch = epoch
        // `budget`'s default can't be spelled as `= .shared` in the parameter
        // list itself: default-argument expressions aren't evaluated in the
        // enclosing (main-actor) isolation context, so referencing a
        // main-actor-isolated static there is a Swift 6 isolation error.
        // Resolving it here, inside the (main-actor-isolated) initializer
        // body, is equivalent for every real caller.
        self.budget = budget ?? .shared
        self.maxAccumulatedBase64Bytes = maxAccumulatedBase64Bytes
        self.diskStore = diskStore
    }

    /// Feeds raw terminal output bytes. Safe to call with any chunking of the
    /// underlying byte stream — the scanner carries state across calls, so a
    /// frame split across arbitrary `ingest` boundaries still parses.
    func ingest(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            process(byte)
        }
    }

    /// The newest version currently retained for `(imageId, placementId)`, or
    /// `nil` if that exact placement isn't active (never activated, only a
    /// *different* placement of this id was, or this one was specifically
    /// deleted), or is active but the id no longer has any retained data at
    /// all (e.g. reclaimed by grace-cache/budget eviction) — either way,
    /// nothing a fresh scan should discover. `placementId` defaults to `0`
    /// (the Kitty spec's implicit default placement) so every call site that
    /// never deals in multiple placements per image id is unaffected.
    func currentVersion(for imageId: UInt32, placementId: UInt32 = 0) -> UInt64? {
        guard isPlacementActive(imageId: imageId, placementId: placementId) else { return nil }
        return latestVersion[imageId]
    }

    /// One currently-retained image and the wall-clock time it was displayed,
    /// for associating images with transcript turns.
    struct RetainedImageInfo: Sendable {
        let imageId: UInt32
        let version: UInt64
        let displayedAt: Date
    }

    /// Snapshot of every image this session currently advertises (retained data
    /// + an active placement, exactly what `/terminal-image` can still serve)
    /// paired with the time it was displayed. Restored-from-disk images have no
    /// display time and are omitted, so a caller can only ever associate an
    /// image whose bytes are guaranteed fetchable. Bounded by the per-session
    /// retention caps (`remoteKittyMaxRetainedEntries`), so this is always small.
    func retainedImageMetadata() -> [RetainedImageInfo] {
        var result: [RetainedImageInfo] = []
        for key in order {
            // `latestVersion[id] == key.version` selects the single current
            // retained version per id; `isAnyPlacementActive` accepts an image
            // shown via any placement (not just the default `p=0`), matching
            // what a fetch can still serve.
            guard latestVersion[key.imageId] == key.version else { continue }
            guard isAnyPlacementActive(imageId: key.imageId) else { continue }
            guard let when = displayedAt[key] else { continue }
            result.append(
                RetainedImageInfo(imageId: key.imageId, version: key.version, displayedAt: when)
            )
        }
        return result
    }

    /// Whether `(imageId, placementId)` is currently active, independent of
    /// whether any data is still retained for it — a wildcard-active id
    /// (every placement active, `a=T`/`a=p` with no explicit `p=`) counts
    /// unless this exact placement was specifically deleted afterward
    /// (`deletedPlacements`); otherwise only an exact `a=T`/`a=p` activation
    /// for this precise pair counts.
    private func isPlacementActive(imageId: UInt32, placementId: UInt32) -> Bool {
        let key = PlacementKey(imageId: imageId, placementId: placementId)
        if deletedPlacements.contains(key) { return false }
        if wildcardActiveImageIds.contains(imageId) { return true }
        return exactActivePlacements.contains(key)
    }

    /// Whether `imageId` has *any* active placement at all (wildcard or any
    /// exact placement), regardless of which specific placement id. Used
    /// where the exact placement being scanned doesn't matter — only
    /// whether this id currently shows anything at all — e.g. deciding
    /// whether a fresh retain's new version changes what a scan would
    /// currently discover.
    private func isAnyPlacementActive(imageId: UInt32) -> Bool {
        if wildcardActiveImageIds.contains(imageId) { return true }
        return exactActivePlacements.contains { $0.imageId == imageId }
    }

    /// Whether `imageId` is both active (`isAnyPlacementActive`) *and* still
    /// has retained data — i.e. whether a fresh scan would currently
    /// discover *something* for it (not necessarily every placement, if
    /// only some are exactly active).
    private func isAnyPlacementAdvertised(imageId: UInt32) -> Bool {
        latestVersion[imageId] != nil && isAnyPlacementActive(imageId: imageId)
    }

    /// Whether the exact `(imageId, placementId)` pair is both active and
    /// still has retained data — i.e. whether a fresh scan would currently
    /// discover this *specific* placement.
    private func isPlacementAdvertised(imageId: UInt32, placementId: UInt32) -> Bool {
        latestVersion[imageId] != nil && isPlacementActive(imageId: imageId, placementId: placementId)
    }

    /// Placement-agnostic version of "is this currently advertised": true
    /// iff `version` is `imageId`'s newest still-retained version *and* the
    /// id has *any* active placement at all — wildcard or exact, and taking
    /// `deletedPlacements` exceptions into account — regardless of which
    /// specific placement id that happens to be.
    ///
    /// Exists because `currentVersion(for:placementId:)` only ever answers
    /// "is this current *for the Kitty spec's implicit default placement
    /// (`0`)*" — fine for a scan of a specific placement, but wrong for
    /// deciding an eviction victim: an id shown only via some other explicit
    /// placement (`a=T,p=5`, say) is every bit as current/visible as one
    /// shown via the default placement, yet `currentVersion(for:)` (called
    /// with its default `placementId: 0`) would report it as not current at
    /// all, making its retained bytes look like fair game for eviction ahead
    /// of some other id's *actually* obsolete version. Both the process-wide
    /// budget's and this instance's own local "prefer evicting superseded
    /// entries" victim selection use this instead.
    func isCurrentlyAdvertised(imageId: UInt32, version: UInt64) -> Bool {
        guard latestVersion[imageId] == version else { return false }
        return isAnyPlacementActive(imageId: imageId)
    }

    /// Activates a placement for `imageId`: either the wildcard (every
    /// placement active, and any prior scoped per-placement deletion
    /// exceptions *and* now-redundant exact-active entries for this id are
    /// cleared — a fresh unscoped activation supersedes them all) when
    /// `explicitPlacementId` is `nil`, or exactly the one named placement
    /// (clearing only its own deletion exception, if any) when it isn't.
    ///
    /// When an explicit placement id is given and `imageId` is *already*
    /// wildcard-active, no new `exactActivePlacements` entry is recorded at
    /// all: the wildcard already covers this (and every other) placement of
    /// the id unless overridden by a deletion exception, which removing
    /// `key` from `deletedPlacements` below already achieves — an exact
    /// entry alongside it would never change what `isPlacementActive` (which
    /// checks the wildcard first) discovers, so recording one would only let
    /// repeated `a=p,p=<n>` for an already-wildcard-active id grow that set
    /// for no discoverable benefit. New exact entries otherwise go through
    /// `makeRoomForPlacementActivityEntry` first, enforcing
    /// `remoteKittyMaxPlacementActivityEntries` fail-closed.
    private func activatePlacement(imageId: UInt32, explicitPlacementId: UInt32?) {
        if let placementId = explicitPlacementId {
            let key = PlacementKey(imageId: imageId, placementId: placementId)
            if wildcardActiveImageIds.contains(imageId) {
                deletedPlacements.remove(key)
            } else {
                if !exactActivePlacements.contains(key) {
                    makeRoomForPlacementActivityEntry(imageId: imageId)
                }
                exactActivePlacements.insert(key)
                deletedPlacements.remove(key)
            }
        } else {
            wildcardActiveImageIds.insert(imageId)
            deletedPlacements = deletedPlacements.filter { $0.imageId != imageId }
            // Every specific exact-active entry for this id is now
            // redundant — the wildcard alone already covers them all.
            exactActivePlacements = exactActivePlacements.filter { $0.imageId != imageId }
            placementDimensions = placementDimensions.filter {
                $0.key.imageId != imageId || $0.key.placementId == nil
            }
        }
    }

    /// Fail-closed guard invoked immediately before inserting a *new* (not
    /// already-present) entry into `exactActivePlacements` or
    /// `deletedPlacements`, guaranteeing their combined count can never
    /// exceed `remoteKittyMaxPlacementActivityEntries`. A pure no-op — the
    /// ordinary case for every real session's placement churn — whenever
    /// headroom already exists.
    ///
    /// When the cap is already reached, this fails closed rather than let
    /// the caller silently overshoot it: it first deactivates and prunes
    /// every bit of `imageId`'s *own* contribution (its wildcard flag, its
    /// exact placements, its deletion exceptions) — the common case, since a
    /// single id spamming many distinct placement ids through `a=p` or
    /// scoped `d=i,...,p=` deletes for itself is exactly what drives the cap
    /// in the first place, so clearing just that id's own entries reliably
    /// makes room again. If the combined count is *still* at the cap
    /// afterward (only possible when enough entries from *other* ids
    /// collectively fill it), every id's placement activity is cleared
    /// outright instead of leaving the cap violated or picking an arbitrary
    /// victim among unrelated ids.
    ///
    /// `imageAvailabilityGeneration` bumps at most once here, and only if
    /// this pruning actually changed what a fresh scan would currently
    /// discover — never for state that was never advertised in the first
    /// place (e.g. an exact placement whose id has no retained data left).
    private func makeRoomForPlacementActivityEntry(imageId: UInt32) {
        guard exactActivePlacements.count + deletedPlacements.count >= remoteKittyMaxPlacementActivityEntries
        else { return }

        let hadOwnAdvertised = isAnyPlacementAdvertised(imageId: imageId)
        wildcardActiveImageIds.remove(imageId)
        exactActivePlacements = exactActivePlacements.filter { $0.imageId != imageId }
        deletedPlacements = deletedPlacements.filter { $0.imageId != imageId }
        placementDimensions = placementDimensions.filter { $0.key.imageId != imageId }
        var changedAdvertised = hadOwnAdvertised
        var clearedPersistenceIds: Set<UInt32> = [imageId]

        if exactActivePlacements.count + deletedPlacements.count >= remoteKittyMaxPlacementActivityEntries {
            let affectedIds = wildcardActiveImageIds.union(exactActivePlacements.map(\.imageId))
            let hadOtherAdvertised = wildcardActiveImageIds.contains { latestVersion[$0] != nil }
                || exactActivePlacements.contains { latestVersion[$0.imageId] != nil }
            wildcardActiveImageIds.removeAll()
            exactActivePlacements.removeAll()
            deletedPlacements.removeAll()
            placementDimensions.removeAll()
            changedAdvertised = changedAdvertised || hadOtherAdvertised
            clearedPersistenceIds.formUnion(affectedIds)
        }
        clearPersistedSelections(imageIds: clearedPersistenceIds)

        if changedAdvertised {
            imageAvailabilityGeneration &+= 1
        }
    }

    private func makeRoomForPlacementGeometry(_ key: PlacementGeometryKey) {
        guard placementDimensions[key] == nil,
              placementDimensions.count >= remoteKittyMaxPlacementActivityEntries
        else { return }
        var clearedPersistenceIds: Set<UInt32> = []
        if placementDimensions.keys.contains(where: { $0.imageId == key.imageId }) {
            clearedPersistenceIds.insert(key.imageId)
        }
        placementDimensions = placementDimensions.filter { $0.key.imageId != key.imageId }
        if placementDimensions.count >= remoteKittyMaxPlacementActivityEntries {
            clearedPersistenceIds.formUnion(placementDimensions.keys.map(\.imageId))
            placementDimensions.removeAll()
        }
        clearPersistedSelections(imageIds: clearedPersistenceIds)
    }

    /// Exposes this instance's fixed epoch (otherwise `private`) so tests can
    /// assert distinct/random epochs without duplicating the version-bit
    /// layout. Not used by any production call site.
    var epochForTesting: UInt32 { epoch }

    /// Total count of every placement-lifecycle-activity entry currently
    /// tracked (wildcard-active ids, exact-active placements, and scoped
    /// deletion exceptions combined) — exposed only so tests can assert this
    /// bounded-state guarantee directly: these sets must never grow with
    /// every historical id a long-lived session has ever seen (finding #5),
    /// *and* the combined exact/deleted total must never exceed
    /// `remoteKittyMaxPlacementActivityEntries` even when every entry
    /// belongs to a single still-retained image id churned through many
    /// distinct placement ids. Not used by any production call site.
    var lifecycleActivityStateCountForTesting: Int {
        wildcardActiveImageIds.count
            + exactActivePlacements.count
            + deletedPlacements.count
            + placementDimensions.count
    }

    /// The exact PNG bytes for `(imageId, version)`, or `nil` if that exact pair
    /// isn't (or is no longer) retained.
    func imageData(imageId: UInt32, version: UInt64) -> Data? {
        dataByKey[StoredKey(imageId: imageId, version: version)]
    }

    // MARK: Byte-level APC scanning

    private func process(_ byte: UInt8) {
        // CAN (0x18) / SUB (0x1A) are wired as an "anywhere" rule in
        // SwiftTerm's own VT500 transition table — they fire from every
        // parser state and always cancel back to ground, never completing
        // whatever escape sequence or control string was in progress. Mirror
        // that here so this scanner can never wedge on a byte stream that
        // happens to contain one mid-OSC/DCS/PM-skip or mid-APC-accumulation:
        // the in-progress sequence is unconditionally discarded (not
        // completed), exactly as a real terminal would resync.
        if byte == 0x18 || byte == 0x1A {
            cancelSequence()
            return
        }
        switch state {
        case .ground:
            if byte == 0x1B { state = .sawEsc }
        case .sawEsc:
            if byte == 0x5F { // '_' — APC start
                clearRawFrame()
                state = .apcAwaitingMarker
            } else if byte == 0x1B {
                state = .sawEsc // a fresh ESC restarts the lookahead window
            } else if byte == 0x5D { // ']' — OSC start (BEL- or ST-terminated)
                state = .controlStringSkipping(allowsBEL: true)
            } else if byte == 0x50 { // 'P' — DCS start (ST-terminated only)
                state = .controlStringSkipping(allowsBEL: false)
            } else if byte == 0x5E { // '^' — PM start (ST-terminated only)
                state = .controlStringSkipping(allowsBEL: false)
            } else {
                state = .ground
            }
        case .apcAwaitingMarker:
            if byte == 0x47 { // 'G' — Kitty graphics APC
                state = .apcAccumulating
            } else if byte == 0x1B {
                abortAPC(reprocessing: byte)
            } else if byte == 0x9C || byte == 0x07 {
                // C1 ST or BEL arriving before the command marker: no command
                // byte was ever accumulated, so — mirroring SwiftTerm, whose
                // shared apc/oscEnd action never dispatches an empty payload
                // — there's nothing to complete, only to abandon.
                clearRawFrame()
                state = .ground
            } else {
                state = .apcSkipping // some other APC payload; not our subset
            }
        case .apcAccumulating:
            if byte == 0x1B {
                state = .apcAccumulatingEsc
            } else if byte == 0x9C || byte == 0x07 {
                // C1 ST (0x9C) or BEL (0x07): SwiftTerm's own table treats
                // both, alongside the 7-bit `ESC \` handled below, as valid
                // terminators for an APC string, so a frame ending on either
                // completes successfully exactly like a full ST would.
                completeFrame()
                state = .ground
            } else if rawFrame.count >= remoteKittyMaxRawFrameBytes {
                // Overflow: drop the frame and resynchronize on the next
                // terminator so a later valid frame still parses.
                clearRawFrame()
                state = .apcSkipping
            } else {
                rawFrame.append(byte)
            }
        case .apcAccumulatingEsc:
            if byte == 0x5C { // '\' — ST, frame complete
                completeFrame()
                state = .ground
            } else {
                abortAPC(reprocessing: byte)
            }
        case .apcSkipping:
            if byte == 0x1B {
                state = .apcSkippingEsc
            } else if byte == 0x9C || byte == 0x07 {
                // Terminates the abandoned (unsupported-subset) frame, same
                // as `ESC \` would via `.apcSkippingEsc` below — discarded,
                // never completed, since it was never our own Kitty subset.
                clearRawFrame()
                state = .ground
            }
        case .apcSkippingEsc:
            if byte == 0x5C {
                state = .ground
            } else if byte == 0x5F {
                // '_' immediately after the ESC we were watching as a possible
                // ST: this is the universal APC-start marker, so a fresh frame
                // begins right here rather than being swallowed back into skip
                // mode (which would otherwise let this frame's own terminator
                // masquerade as the end of the abandoned one).
                clearRawFrame()
                state = .apcAwaitingMarker
            } else if byte != 0x1B {
                state = .apcSkipping
            }
        case .controlStringSkipping(let allowsBEL):
            if allowsBEL && byte == 0x07 { // BEL — OSC's alternate terminator
                state = .ground
            } else if byte == 0x9C { // C1 ST — terminates OSC/DCS/PM alike
                state = .ground
            } else if byte == 0x1B {
                state = .controlStringSkippingEsc(allowsBEL: allowsBEL)
            }
            // Any other byte — including one that would otherwise look like
            // our own APC start (`_`) or its marker (`G`) — is just more of
            // this string's payload: a string sequence never nests, so only
            // its own terminator (checked above/below) can ever end it.
        case .controlStringSkippingEsc(let allowsBEL):
            if byte == 0x5C { // '\' — ST, string complete
                state = .ground
            } else if byte != 0x1B {
                // Not a real ST after all: back into the string body, and
                // this byte (which could itself be `_`) is simply more
                // payload, never a fresh APC/OSC/DCS/PM marker.
                state = .controlStringSkipping(allowsBEL: allowsBEL)
            }
            // else: a fresh ESC keeps this lookahead window open, mirroring
            // `.sawEsc`'s own handling of consecutive ESCs.
        }
    }

    /// Discards any partially buffered frame and resynchronizes, then
    /// reprocesses `byte` — so a byte that turned out not to be a valid ST is
    /// never silently swallowed. Special-cased for `byte == '_'`: since the
    /// ESC that led here was already consumed, falling through to `.ground`
    /// and reprocessing `_` there would lose the "ESC _" prefix entirely
    /// (`.ground` only reacts to a *subsequent* ESC) — so a fresh APC starts
    /// directly instead, exactly as `.apcSkippingEsc` does for the same byte.
    private func abortAPC(reprocessing byte: UInt8) {
        clearRawFrame()
        if byte == 0x5F {
            state = .apcAwaitingMarker
            return
        }
        state = .ground
        process(byte)
    }

    /// CAN/SUB "anywhere" cancellation (see `process(_:)`): unconditionally
    /// discards any partially buffered frame and resets to `.ground`, never
    /// completing or reprocessing the cancelling byte itself.
    private func cancelSequence() {
        clearRawFrame()
        state = .ground
    }

    /// Empties `rawFrame`, releasing its underlying storage
    /// (`keepingCapacity: false`) if it had grown past
    /// `remoteKittyLargeBufferReleaseThreshold` before being discarded — so a
    /// frame that grew large (e.g. right up to `remoteKittyMaxRawFrameBytes`)
    /// doesn't leave that much capacity pinned per terminal indefinitely.
    private func clearRawFrame() {
        if rawFrame.count > remoteKittyLargeBufferReleaseThreshold {
            rawFrame.removeAll(keepingCapacity: false)
        } else {
            rawFrame.removeAll(keepingCapacity: true)
        }
    }

    private func completeFrame() {
        let frame = rawFrame
        clearRawFrame()
        let controlBytes: ArraySlice<UInt8>
        let payloadBytes: ArraySlice<UInt8>
        if let semicolon = frame.firstIndex(of: 0x3B) {
            controlBytes = frame[frame.startIndex ..< semicolon]
            payloadBytes = frame[(semicolon + 1)...]
        } else {
            controlBytes = frame[...]
            payloadBytes = frame[frame.endIndex...]
        }
        guard let control = String(bytes: controlBytes, encoding: .ascii) else { return }
        handleControlData(Self.parseControlData(control), payload: payloadBytes)
    }

    private static func parseControlData(_ control: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in control.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    // MARK: Command handling

    private func handleControlData(_ keys: [String: String], payload: ArraySlice<UInt8>) {
        if let action = keys["a"] {
            switch action {
            case "T", "t":
                beginTransmission(keys: keys, payload: payload)
            case "d":
                handleDelete(keys: keys)
            case "p":
                handlePlacement(keys: keys)
            default:
                break // unsupported action (query/animation/...): ignore
            }
            return
        }
        // No action key at all: only meaningful as an `m=1`/`m=0` continuation
        // chunk of an already-started transmission.
        appendContinuation(payload: payload, more: keys["m"] == "1")
    }

    private func beginTransmission(keys: [String: String], payload: ArraySlice<UInt8>) {
        // The protocol requires a client to finish all chunks of a transmission
        // before sending another graphics command, so a fresh start always means
        // any previous in-flight transmission is incomplete — abandon it.
        resetPendingTransmission()

        let transmissionMedium = keys["t"] ?? "d"
        guard transmissionMedium == "d",
              keys["f"] == "100",
              keys["U"] == "1",
              let idString = keys["i"],
              let imageId = UInt32(idString),
              imageId >= 1, imageId <= 0xFFFFFF
        else {
            return // outside our supported subset: fail closed, ignore entirely
        }

        pendingImageId = imageId
        // `a=T` (transmit + display) always activates a placement once this
        // transmission finalizes; `a=t` (transmit only) never does on its
        // own — `retain(...)` additionally preserves (never clears) whatever
        // activity already existed for `imageId` regardless of which action
        // this is, so a plain `t` on an already-active id keeps showing it.
        pendingActivates = (keys["a"] == "T")
        pendingPlacementId = keys["p"].flatMap { UInt32($0) }.flatMap {
            $0 > 0 ? $0 : nil
        }
        pendingRows = keys["r"].flatMap { Int($0) }.flatMap {
            $0 > 0 && $0 <= remoteKittyMaxImageDimension ? $0 : nil
        }
        pendingColumns = keys["c"].flatMap { Int($0) }.flatMap {
            $0 > 0 && $0 <= remoteKittyMaxImageDimension ? $0 : nil
        }
        pendingX = keys["X"].flatMap { Int($0) }
        pendingY = keys["Y"].flatMap { Int($0) }
        pendingZ = keys["z"].flatMap { Int($0) }
        appendPayload(payload)
        if keys["m"] != "1" { finalizePending() }
    }

    /// Handles `a=p` — re-placement using bytes already retained from a
    /// prior transmission (never a fresh payload of its own): activates
    /// `i=<id>`'s placement (wildcard, or exactly `p=<placement>` if given)
    /// without installing any new version, so a subsequent scan can
    /// discover it again using the same content version it already had.
    /// A no-op if the id has no retained data at all (nothing to
    /// re-place), mirroring every other command's fail-closed handling of
    /// an id it can't currently serve.
    private func handlePlacement(keys: [String: String]) {
        // Same one-in-flight-transmission-at-a-time rule as `a=T`/`a=t`: a
        // fresh graphics command always abandons whatever transmission was
        // still pending.
        resetPendingTransmission()

        guard keys["U"] == "1",
              let idString = keys["i"], let imageId = UInt32(idString),
              imageId >= 1, imageId <= 0xFFFFFF,
              latestVersion[imageId] != nil
        else { return }

        let wasAdvertised = isAnyPlacementAdvertised(imageId: imageId)
        let explicitPlacementId = keys["p"].flatMap { UInt32($0) }.flatMap {
            $0 > 0 ? $0 : nil
        }
        if let rows = keys["r"].flatMap({ Int($0) }),
           let columns = keys["c"].flatMap({ Int($0) }),
           rows > 0, columns > 0,
           rows <= remoteKittyMaxImageDimension,
           columns <= remoteKittyMaxImageDimension {
            let geometryKey = PlacementGeometryKey(
                imageId: imageId,
                placementId: explicitPlacementId
            )
            makeRoomForPlacementGeometry(geometryKey)
            placementDimensions[geometryKey] = PlacementDimensions(
                rows: rows,
                columns: columns,
                x: keys["X"].flatMap { Int($0) },
                y: keys["Y"].flatMap { Int($0) },
                z: keys["z"].flatMap { Int($0) }
            )
        }
        activatePlacement(imageId: imageId, explicitPlacementId: explicitPlacementId)
        // Bump iff this re-placement could change what a fresh scan
        // currently discovers: it does exactly when the id wasn't already
        // fully advertised before (an already wildcard-active id gaining a
        // redundant exact activation, or vice versa, changes nothing a scan
        // would currently see).
        if !wasAdvertised {
            imageAvailabilityGeneration &+= 1
        }
        syncPersistedSelections(imageId: imageId)
    }

    private func appendContinuation(payload: ArraySlice<UInt8>, more: Bool) {
        guard pendingImageId != nil else { return }
        appendPayload(payload)
        if !more { finalizePending() }
    }

    private func appendPayload(_ payload: ArraySlice<UInt8>) {
        guard pendingImageId != nil else { return }
        // Reserved against the process-wide pending budget *before* actually
        // appending, so a chunk that would push either this instance's own
        // local cap or the shared cross-terminal cap over its bound is never
        // partially retained — the whole in-flight transmission is discarded
        // instead, exactly like any other overflow.
        guard pendingBase64.count + payload.count <= maxAccumulatedBase64Bytes,
              budget.reservePending(owner: self, additionalBytes: payload.count)
        else {
            resetPendingTransmission()
            return
        }
        pendingBase64.append(contentsOf: payload)
    }

    private func finalizePending() {
        defer { resetPendingTransmission() }
        guard let imageId = pendingImageId,
              let decoded = Data(base64Encoded: Data(pendingBase64)),
              decoded.count <= remoteKittyMaxDecodedImageBytes,
              RemoteKittyPNGValidation.isStructurallyValid(decoded)
        else { return }
        retain(imageId: imageId, data: decoded, activates: pendingActivates, explicitPlacementId: pendingPlacementId)
    }

    /// Ends whatever in-flight transmission is currently buffered — on
    /// success, failure, overflow, a fresh `beginTransmission` abandoning the
    /// previous one, or an explicit delete/clear — releasing this exact
    /// buffer's process-wide pending-byte reservation (never partially: the
    /// whole in-flight transmission is one all-or-nothing unit) and its local
    /// storage, dropping capacity if it had grown large.
    private func resetPendingTransmission() {
        pendingImageId = nil
        pendingActivates = false
        pendingPlacementId = nil
        pendingRows = nil
        pendingColumns = nil
        pendingX = nil
        pendingY = nil
        pendingZ = nil
        clearPendingBase64()
        budget.releasePending(owner: self)
    }

    /// Called by `RemoteKittyImageCaptureBudget` when it needs to abort this
    /// exact owner's in-flight transmission to make room for a different
    /// owner's pending reservation (see `RemoteKittyImageCaptureBudget
    /// .reservePending`) — the pending-bytes counterpart to `evictForBudget`
    /// for retained entries. Safe unconditionally: unvalidated pending bytes
    /// aren't real data any other owner could be relying on yet. Never
    /// re-notifies the budget (it already removed this owner's reservation
    /// on its side, which is what triggered this call in the first place) —
    /// calling `resetPendingTransmission` here instead would double-release.
    func abortPendingForBudget() {
        pendingImageId = nil
        pendingActivates = false
        pendingPlacementId = nil
        pendingRows = nil
        pendingColumns = nil
        pendingX = nil
        pendingY = nil
        pendingZ = nil
        clearPendingBase64()
    }

    /// Empties `pendingBase64`, releasing its underlying storage
    /// (`keepingCapacity: false`) if it had grown past
    /// `remoteKittyLargeBufferReleaseThreshold` before being discarded — so a
    /// large in-flight buffer doesn't leave that much capacity pinned per
    /// terminal indefinitely once its transmission ends.
    private func clearPendingBase64() {
        if pendingBase64.count > remoteKittyLargeBufferReleaseThreshold {
            pendingBase64.removeAll(keepingCapacity: false)
        } else {
            pendingBase64.removeAll(keepingCapacity: true)
        }
    }

    /// Allocates this instance's next version: monotonic `counter` in the low
    /// 32 bits, this instance's fixed `epoch` in the high 32 bits.
    private func nextVersion() -> UInt64 {
        let version = (UInt64(epoch) << 32) | nextCounter
        nextCounter += 1
        return version
    }

    private func retain(imageId: UInt32, data: Data, activates: Bool, explicitPlacementId: UInt32?) {
        let version = nextVersion()
        let key = StoredKey(imageId: imageId, version: version)
        order.append(key)
        dataByKey[key] = data
        displayedAt[key] = Date()
        totalBytes += data.count
        if activates, let rows = pendingRows, let columns = pendingColumns {
            let geometryKey = PlacementGeometryKey(
                imageId: imageId,
                placementId: explicitPlacementId
            )
            makeRoomForPlacementGeometry(geometryKey)
            placementDimensions[geometryKey] = PlacementDimensions(
                rows: rows, columns: columns, x: pendingX, y: pendingY, z: pendingZ
            )
        }
        // Whether a *previous* version was already being advertised for
        // `imageId` — captured before either `latestVersion` or activation
        // state changes below — determines whether this retain's new
        // version necessarily changes what a scan currently discovers.
        let hadAdvertisedVersion = latestVersion[imageId] != nil && isAnyPlacementActive(imageId: imageId)
        latestVersion[imageId] = version
        // `a=T` (transmit + display) always (re)activates a placement —
        // whether `imageId` was previously active, had its placement
        // deleted but was still retained, or is being seen for the first
        // time entirely. `a=t` (transmit only) never activates anything on
        // its own — it only ever stores new bytes/version, preserving
        // (never touching) whatever activation state already existed, so a
        // `t` on an already-active id keeps showing it (with the new
        // version) while a `t` on an inactive id stays inactive.
        if activates {
            activatePlacement(imageId: imageId, explicitPlacementId: explicitPlacementId)
        }
        let isAdvertisedNow = isAnyPlacementActive(imageId: imageId)
        // Bump iff this retain could change what a fresh scan currently
        // discovers for `imageId`: either a previously-advertised version is
        // now superseded by this new one (still active, so the id's
        // discoverable version just changed), or the id just became newly
        // advertised (a `T`/`p` activation, first-time or reactivating). A
        // plain `t` that leaves an already-inactive id inactive changes
        // nothing a scan would see, so it must not bump.
        if hadAdvertisedVersion || isAdvertisedNow {
            imageAvailabilityGeneration &+= 1
        }
        persistRetainToDisk(
            imageId: imageId,
            version: version,
            data: data,
            selections: persistedSelections(imageId: imageId)
        )
        budget.register(owner: self, imageId: imageId, version: version, bytes: data.count)
        enforceLocalBounds()
    }

    /// Removes a single retained entry, keeping `order`/`dataByKey`/`totalBytes`/
    /// `latestVersion` in lockstep. `notifyBudget` is false only when this is
    /// itself being called *from* the budget manager's own eviction (avoiding a
    /// pointless unregister-of-something-it-just-removed callback).
    private func removeStoredKey(_ key: StoredKey, notifyBudget: Bool) {
        guard let data = dataByKey.removeValue(forKey: key) else { return }
        totalBytes -= data.count
        displayedAt.removeValue(forKey: key)
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        if latestVersion[key.imageId] == key.version {
            latestVersion.removeValue(forKey: key.imageId)
            // The entry just reclaimed was `imageId`'s *current* version. A
            // scan would no longer find it *only if* the id was still active
            // (an already-inactive id was never advertised in the first
            // place, so its data quietly aging out here doesn't change what
            // a scan would currently discover — bumping would be a pointless
            // extra generation bump). The active set itself is untouched:
            // per the spec, retained-data eviction never implies a placement
            // was deleted, only that it can no longer be served.
            if isAnyPlacementActive(imageId: key.imageId) {
                imageAvailabilityGeneration &+= 1
            }
            syncPersistedSelections(imageId: key.imageId)
        }
        // Bound lifecycle state to ids that still have *some* retained data:
        // once no entry (current or older grace-retained) remains anywhere
        // in `order` for this id, its wildcard/exact/deleted-placement state
        // can never again be discovered by any scan (which always requires
        // `latestVersion[imageId] != nil` too) until a fresh transmission
        // retains new bytes for it — so pruning here is behavior-neutral for
        // every scan from this point until then, while keeping these sets
        // from growing forever with every historical id a long-lived session
        // ever happened to see.
        if !order.contains(where: { $0.imageId == key.imageId }) {
            wildcardActiveImageIds.remove(key.imageId)
            exactActivePlacements = exactActivePlacements.filter { $0.imageId != key.imageId }
            deletedPlacements = deletedPlacements.filter { $0.imageId != key.imageId }
            placementDimensions = placementDimensions.filter { $0.key.imageId != key.imageId }
        }
        if notifyBudget {
            budget.unregister(owner: self, imageId: key.imageId, version: key.version)
        }
        // Mirrors this exact entry's removal onto disk regardless of
        // `notifyBudget` — a local grace-cache eviction and a cross-session
        // budget eviction (`evictForBudget`) must both stop this session's
        // durable store from ever restoring bytes memory no longer has.
        persistEvictionToDisk(imageId: key.imageId, version: key.version)
    }

    /// Called by `RemoteKittyImageCaptureBudget` when it needs to reclaim this
    /// exact entry to enforce the process-wide bound. Never re-notifies the
    /// budget (it's already accounted for the removal on its side).
    func evictForBudget(imageId: UInt32, version: UInt64) {
        removeStoredKey(StoredKey(imageId: imageId, version: version), notifyBudget: false)
    }

    private func enforceLocalBounds() {
        while order.count > remoteKittyMaxRetainedEntries || totalBytes > remoteKittyMaxTotalRetainedBytes {
            guard let victim = pickEvictionVictim() else { break }
            removeStoredKey(victim, notifyBudget: true)
        }
    }

    /// Prefers evicting the oldest already-superseded version (an id's older,
    /// grace-retained entry) over any still-current one, so bumping into the
    /// bound never drops a version a client might currently be looking at as
    /// long as some obsolete version is available to sacrifice instead.
    /// Uses the placement-agnostic `isCurrentlyAdvertised` rather than
    /// comparing directly against `latestVersion` so this also correctly
    /// prefers evicting a fully-inactive "ghost" entry (an id whose only
    /// retained version is still `latestVersion`, but whose placement was
    /// deleted, so nothing can discover it any more) over a genuinely
    /// still-advertised entry belonging to some other id.
    private func pickEvictionVictim() -> StoredKey? {
        guard !order.isEmpty else { return nil }
        for key in order where !isCurrentlyAdvertised(imageId: key.imageId, version: key.version) {
            return key
        }
        return order.first
    }

    // MARK: Deletion

    private func handleDelete(keys: [String: String]) {
        // An interrupted `m=1` upload must never be able to finalize *after*
        // a delete — abandoning any pending transmission here, before any
        // lifecycle handling below, guarantees that regardless of which
        // delete mode/scope follows, no later continuation chunk can
        // complete a transmission that started before this delete and
        // (re)activate/store data the delete just intended to remove.
        resetPendingTransmission()

        let mode = keys["d"] ?? "a"
        let explicitPlacementId = keys["p"].flatMap { UInt32($0) }.flatMap {
            $0 > 0 ? $0 : nil
        }
        switch mode {
        case "A":
            clearAll()
        case "I":
            guard let idString = keys["i"], let imageId = UInt32(idString) else { return }
            if let placementId = explicitPlacementId {
                // `d=I,i=<id>,p=<placement>`: mirrors SwiftTerm's own
                // uppercase scoping — remove only *this* placement's
                // activity first (exactly like the lowercase `d=i,...,p=`
                // scoped delete above), then free the underlying retained
                // bytes/versions too, but only if no sibling placement of
                // this same image id is still active afterward. If a
                // sibling (wildcard or another exact placement) survives,
                // the bytes/current version must remain retained and
                // advertised for it — an uppercase delete scoped to one
                // placement must never nuke data another still-visible
                // placement of the same id depends on.
                clearSpecificPlacement(imageId: imageId, placementId: placementId)
                if !isAnyPlacementActive(imageId: imageId) {
                    removeAllVersions(imageId: imageId)
                }
            } else {
                // `d=I,i=<id>` with no `p=`: removes every placement *and*
                // all retained data/versions for this id.
                removeAllVersions(imageId: imageId)
            }
        case "a":
            clearAllActivePlacements()
        case "i":
            guard let idString = keys["i"], let imageId = UInt32(idString) else { return }
            if let placementId = explicitPlacementId {
                // `d=i,i=<id>,p=<placement>`: scoped to exactly one
                // placement of this image — every other placement sharing
                // the same image id must remain advertised untouched.
                clearSpecificPlacement(imageId: imageId, placementId: placementId)
            } else {
                // `d=i,i=<id>` with no `p=`: removes *all* activity for
                // this id.
                clearActivePlacement(imageId: imageId)
            }
        default:
            // Every other delete mode this instance doesn't specifically
            // understand the scoping of (column/row/z-index/point/animation-
            // frame targeted deletes, upper- or lowercase) is handled fail
            // closed rather than silently ignored — *except* when the
            // command still names both an image id and an explicit
            // placement id: a delete scoped that precisely must never be
            // allowed to nuke every other placement sharing the same image
            // id just because this capture doesn't recognize the outer mode
            // letter, so that one placement is targeted exactly as `d=i`
            // would. Otherwise, an uppercase mode also deletes underlying
            // data per the Kitty spec, and since this capture can't reason
            // about exactly *which* placements/data an unscoped instance of
            // such a delete would target, it conservatively treats it the
            // same as the one fully-scoped delete it does understand at
            // that same tier (`A` for uppercase, `a` for lowercase) —
            // clearing more than a real terminal might have, but never
            // leaving a ghost.
            if let idString = keys["i"], let imageId = UInt32(idString), let placementId = explicitPlacementId {
                clearSpecificPlacement(imageId: imageId, placementId: placementId)
            } else if mode.first?.isUppercase == true {
                clearAll()
            } else {
                clearAllActivePlacements()
            }
        }
    }

    /// Removes only `imageId`'s active-placement flag — its retained PNG
    /// bytes (all still-grace-retained versions) are left untouched. Mirrors
    /// the Kitty spec's lowercase `d=i` *without* an explicit `p=`: removes
    /// every bit of this id's activity (wildcard, any exact placements, and
    /// any scoped-deletion exceptions) rather than just one placement.
    /// `currentVersion(for:)` returns `nil` for every placement of this id
    /// afterward (no more ghost) until a fresh transmission or re-placement
    /// reactivates it.
    private func clearActivePlacement(imageId: UInt32) {
        let wasAdvertised = isAnyPlacementAdvertised(imageId: imageId)
        wildcardActiveImageIds.remove(imageId)
        exactActivePlacements = exactActivePlacements.filter { $0.imageId != imageId }
        deletedPlacements = deletedPlacements.filter { $0.imageId != imageId }
        placementDimensions = placementDimensions.filter { $0.key.imageId != imageId }
        if wasAdvertised {
            // Was actually advertised (active *and* retained) before this
            // delete — now it isn't, so a scan's discoverable state changed.
            imageAvailabilityGeneration &+= 1
        }
        syncPersistedSelections(imageId: imageId)
    }

    /// Removes only one specific `(imageId, placementId)` pair's activity —
    /// mirrors the Kitty spec's `d=i,i=<id>,p=<placement>`. Every other
    /// placement of the same image id (wildcard-active or individually
    /// exact-active) is left untouched, so this never over-deletes siblings.
    ///
    /// Recording the deletion exception goes through
    /// `makeRoomForPlacementActivityEntry` first when it would be a *new*
    /// `deletedPlacements` entry, so many distinct placement ids scoped-
    /// deleted under one wildcard-active id (`d=i,i=<id>,p=<n>` for many
    /// `n`) can never grow that set past `remoteKittyMaxPlacementActivityEntries`
    /// either — the fail-closed pruning it performs may itself have already
    /// cleared this id's wildcard-active flag (if `imageId` alone was
    /// driving the cap) or every id's placement activity outright (if it
    /// wasn't), so membership is rechecked fresh afterward rather than
    /// trusting the value read before pruning.
    private func clearSpecificPlacement(imageId: UInt32, placementId: UInt32) {
        let key = PlacementKey(imageId: imageId, placementId: placementId)
        let wasAdvertised = isPlacementAdvertised(imageId: imageId, placementId: placementId)
        exactActivePlacements.remove(key)
        placementDimensions.removeValue(forKey: PlacementGeometryKey(
            imageId: imageId,
            placementId: placementId
        ))
        if wildcardActiveImageIds.contains(imageId) {
            if !deletedPlacements.contains(key) {
                makeRoomForPlacementActivityEntry(imageId: imageId)
            }
            if wildcardActiveImageIds.contains(imageId) {
                // The id is still wildcard-active overall — record this one
                // placement as a specific exception so it alone stops being
                // advertised while every sibling placement keeps working.
                deletedPlacements.insert(key)
            }
            // Else: the cap guard above already deactivated this id (or
            // every id) entirely to make room — this placement (and
            // possibly its siblings) is already hidden, so there's nothing
            // left to record an exception against.
        } else {
            // No wildcard to override; removing the exact activation above
            // already fully deactivates this placement, so no exception
            // needs to be recorded (keeping `deletedPlacements` from
            // growing with entries that would never do anything).
            deletedPlacements.remove(key)
        }
        if wasAdvertised {
            imageAvailabilityGeneration &+= 1
        }
        syncPersistedSelections(imageId: imageId)
    }

    /// Removes every id's active-placement flag entirely (wildcard, exact
    /// placements, and deletion exceptions) — retained PNG bytes for every
    /// id are left untouched. Mirrors the Kitty spec's lowercase `d=a`, and
    /// is also the fail-closed fallback for any other unscoped lowercase
    /// delete mode this capture doesn't specifically scope.
    private func clearAllActivePlacements() {
        guard !wildcardActiveImageIds.isEmpty || !exactActivePlacements.isEmpty else { return }
        // Only ids that were both active *and* still had retained data were
        // actually advertised before this clear — anything else clearing
        // here doesn't change what a scan would currently discover.
        let affectedIds = wildcardActiveImageIds.union(exactActivePlacements.map(\.imageId))
        let hadAnyAdvertised = wildcardActiveImageIds.contains { latestVersion[$0] != nil }
            || exactActivePlacements.contains { latestVersion[$0.imageId] != nil }
        wildcardActiveImageIds.removeAll()
        exactActivePlacements.removeAll()
        deletedPlacements.removeAll()
        placementDimensions.removeAll()
        if hadAnyAdvertised { imageAvailabilityGeneration &+= 1 }
        clearPersistedSelections(imageIds: affectedIds)
    }

    private func clearAll() {
        let hadAnyAdvertised = wildcardActiveImageIds.contains { latestVersion[$0] != nil }
            || exactActivePlacements.contains { latestVersion[$0.imageId] != nil }
        for key in order {
            budget.unregister(owner: self, imageId: key.imageId, version: key.version)
        }
        order.removeAll()
        dataByKey.removeAll()
        displayedAt.removeAll()
        latestVersion.removeAll()
        wildcardActiveImageIds.removeAll()
        exactActivePlacements.removeAll()
        deletedPlacements.removeAll()
        placementDimensions.removeAll()
        totalBytes = 0
        if hadAnyAdvertised { imageAvailabilityGeneration &+= 1 }
        resetPendingTransmission()
        persistClearSessionToDisk()
    }

    private func removeAllVersions(imageId: UInt32) {
        var kept: [StoredKey] = []
        kept.reserveCapacity(order.count)
        for key in order {
            if key.imageId == imageId {
                if let data = dataByKey.removeValue(forKey: key) { totalBytes -= data.count }
                displayedAt.removeValue(forKey: key)
                budget.unregister(owner: self, imageId: key.imageId, version: key.version)
                persistEvictionToDisk(imageId: key.imageId, version: key.version)
            } else {
                kept.append(key)
            }
        }
        order = kept
        let hadData = latestVersion.removeValue(forKey: imageId) != nil
        let wasActive = isAnyPlacementActive(imageId: imageId)
        // All data for `imageId` is gone now, so its lifecycle-activity
        // state can never again be discovered until a fresh transmission —
        // prune it here too (see the matching comment in `removeStoredKey`),
        // rather than only when the *last* version happens to age out via
        // grace-cache/budget eviction.
        wildcardActiveImageIds.remove(imageId)
        exactActivePlacements = exactActivePlacements.filter { $0.imageId != imageId }
        deletedPlacements = deletedPlacements.filter { $0.imageId != imageId }
        placementDimensions = placementDimensions.filter { $0.key.imageId != imageId }
        // Advertised availability only changes if `imageId` was both active
        // and had retained data before this — either alone means it wasn't
        // currently discoverable by a scan, so removing the other half here
        // doesn't change anything a scan would see.
        if wasActive && hadData {
            imageAvailabilityGeneration &+= 1
        }
        if hadData { syncPersistedSelections(imageId: imageId) }
        if pendingImageId == imageId {
            resetPendingTransmission()
        }
    }

    // MARK: - Durable disk persistence (hooks; no-ops without a `diskStore`)

    /// Mirrors one freshly-retained `(imageId, version)` entry's exact bytes
    /// onto disk, asynchronously — a no-op while `suppressPersistToDisk`
    /// (mid-restore) or without a configured `diskStore`.
    private func persistRetainToDisk(
        imageId: UInt32,
        version: UInt64,
        data: Data,
        selections: [RemoteKittyPersistedPlacementSelection]
    ) {
        guard !suppressPersistToDisk, let diskStore else { return }
        diskStore.persistRetain(
            sessionId: sessionId,
            imageId: imageId,
            version: version,
            data: data,
            currentSelections: selections
        )
    }

    /// Mirrors one entry's removal (local grace-cache eviction, cross-session
    /// budget eviction, or an explicit per-id delete) onto disk,
    /// asynchronously.
    private func persistEvictionToDisk(imageId: UInt32, version: UInt64) {
        guard !suppressPersistToDisk, let diskStore else { return }
        diskStore.persistEviction(sessionId: sessionId, imageId: imageId, version: version)
    }

    /// Mirrors a full `d=A`-style clear of every retained entry for this
    /// session onto disk, asynchronously.
    private func persistClearSessionToDisk() {
        guard !suppressPersistToDisk, let diskStore else { return }
        diskStore.persistClearSession(sessionId: sessionId)
    }

    /// Recomputes and persists (or clears) `imageId`'s durable
    /// current-selection record(s) to reflect whatever this instance
    /// currently advertises for it — called after every mutation that can
    /// change `imageId`'s activation state or its `latestVersion`. Persists
    /// nothing (and clears any existing persisted selection) when `imageId`
    /// has no current version, no active placement, or no captured
    /// `c=`/`r=` cell-span metadata to faithfully replay.
    private func syncPersistedSelections(imageId: UInt32) {
        guard !suppressPersistToDisk, let diskStore else { return }
        diskStore.replaceCurrentSelections(
            sessionId: sessionId,
            imageId: imageId,
            selections: persistedSelections(imageId: imageId)
        )
    }

    /// Mirrors one natural multi-image placement clear as one FIFO disk-store
    /// mutation, avoiding a full manifest commit for every affected image id.
    private func clearPersistedSelections(imageIds: Set<UInt32>) {
        guard !suppressPersistToDisk, let diskStore else { return }
        diskStore.clearCurrentSelections(sessionId: sessionId, imageIds: imageIds)
    }

    private func persistedSelections(imageId: UInt32) -> [RemoteKittyPersistedPlacementSelection] {
        guard let version = latestVersion[imageId] else { return [] }
        var selections: [RemoteKittyPersistedPlacementSelection] = []
        if wildcardActiveImageIds.contains(imageId),
           let dims = placementDimensions[PlacementGeometryKey(
               imageId: imageId,
               placementId: nil
           )],
           dims.rows > 0, dims.columns > 0 {
            selections.append(RemoteKittyPersistedPlacementSelection(
                version: version, placementId: nil,
                rows: dims.rows, columns: dims.columns, x: dims.x, y: dims.y, z: dims.z
            ))
        }
        if wildcardActiveImageIds.contains(imageId) {
            for (key, dims) in placementDimensions
                where key.imageId == imageId {
                guard let placementId = key.placementId,
                      !deletedPlacements.contains(PlacementKey(
                          imageId: imageId,
                          placementId: placementId
                      )),
                      dims.rows > 0,
                      dims.columns > 0
                else { continue }
                selections.append(RemoteKittyPersistedPlacementSelection(
                    version: version,
                    placementId: placementId,
                    rows: dims.rows,
                    columns: dims.columns,
                    x: dims.x,
                    y: dims.y,
                    z: dims.z
                ))
            }
        }
        for key in exactActivePlacements where key.imageId == imageId {
            guard let dims = placementDimensions[PlacementGeometryKey(
                imageId: imageId,
                placementId: key.placementId
            )],
                dims.rows > 0, dims.columns > 0
            else { continue }
            selections.append(RemoteKittyPersistedPlacementSelection(
                version: version, placementId: key.placementId,
                rows: dims.rows, columns: dims.columns, x: dims.x, y: dims.y, z: dims.z
            ))
        }
        return selections
    }

    func currentPersistedSelection(
        imageId: UInt32,
        placementId: UInt32?
    ) -> RemoteKittyPersistedPlacementSelection? {
        let normalizedPlacementId = placementId.flatMap { $0 > 0 ? $0 : nil }
        return persistedSelections(imageId: imageId).first {
            ($0.placementId ?? 0) == (normalizedPlacementId ?? 0)
        }
    }

    func disablePersistence() {
        diskStore = nil
    }

    // MARK: - Durable disk restore (never touches disk; never a live command)

    /// Begins a disk-restore replay window: must be followed by any number of
    /// `restoreEntry`/`restoreCurrentSelection` calls, then exactly one
    /// `finishRestoring()`. Every disk-persistence hook above becomes a no-op
    /// for the whole window, so restoring previously-persisted state can
    /// never recursively re-persist it back to the very store it came from.
    func beginRestoring() {
        isRestoring = true
        suppressPersistToDisk = true
        restoreAdvertisedChanged = false
    }

    /// Installs one previously-persisted disk entry directly into this
    /// instance's in-memory retained state, without generating a new version
    /// or touching activation/current-selection state — the restore-only
    /// counterpart to `retain(...)`. Never called from any live Kitty
    /// command. Requires the exact bytes to still pass the same structural
    /// PNG validation a live transmission would (an on-disk PNG is untrusted
    /// input exactly like one arriving over the wire), and is a no-op
    /// (returning `false`) if `(imageId, version)` is already retained (e.g.
    /// a duplicate restore call) — never overwrites or double-counts an
    /// existing entry. Deliberately does *not* register with the
    /// process-wide budget or enforce local bounds yet: see
    /// `pendingBudgetRegistrations`.
    @discardableResult
    func restoreEntry(imageId: UInt32, version: UInt64, data: Data) -> Bool {
        guard isRestoring else { return false }
        guard imageId >= 1, imageId <= 0xFFFFFF,
              RemoteKittyPNGValidation.isStructurallyValid(data)
        else { return false }
        let key = StoredKey(imageId: imageId, version: version)
        guard dataByKey[key] == nil else { return false }
        order.append(key)
        dataByKey[key] = data
        totalBytes += data.count
        latestVersion[imageId] = version
        pendingBudgetRegistrations.append(key)
        return true
    }

    /// Installs one previously-persisted current-selection record — the
    /// restore-only counterpart to a live `a=T`/`a=p` activation. Only
    /// selects an `(imageId, version)` pair that was actually restored by a
    /// prior `restoreEntry` call in this same window (never a dangling
    /// reference to bytes that were never installed), and reuses
    /// `activatePlacement` so wildcard-vs-exact activation semantics are
    /// identical to the live path.
    @discardableResult
    func restoreCurrentSelection(
        imageId: UInt32,
        version: UInt64,
        placementId: UInt32?,
        rows: Int? = nil,
        columns: Int? = nil,
        x: Int? = nil,
        y: Int? = nil,
        z: Int? = nil
    ) -> Bool {
        guard isRestoring else { return false }
        let key = StoredKey(imageId: imageId, version: version)
        guard dataByKey[key] != nil else { return false }
        let normalizedPlacementId = placementId.flatMap { $0 > 0 ? $0 : nil }
        if let rows, let columns,
           rows > 0, columns > 0,
           rows <= remoteKittyMaxImageDimension,
           columns <= remoteKittyMaxImageDimension {
            let geometryKey = PlacementGeometryKey(
                imageId: imageId,
                placementId: normalizedPlacementId
            )
            makeRoomForPlacementGeometry(geometryKey)
            placementDimensions[geometryKey] = PlacementDimensions(
                rows: rows,
                columns: columns,
                x: x,
                y: y,
                z: z
            )
        }
        let wasAdvertised = latestVersion[imageId] != nil && isAnyPlacementActive(imageId: imageId)
        latestVersion[imageId] = version
        activatePlacement(imageId: imageId, explicitPlacementId: normalizedPlacementId)
        if !wasAdvertised { restoreAdvertisedChanged = true }
        return true
    }

    /// Ends a disk-restore replay window begun by `beginRestoring()`:
    /// registers every restored entry with the process-wide budget and
    /// enforces local bounds (deferred until now so eviction preference sees
    /// this session's *final* current-selection state, never a
    /// still-incomplete one — see `pendingBudgetRegistrations`), then bumps
    /// `imageAvailabilityGeneration` at most once for the whole batch if any
    /// restored current availability actually changed. Safe to call even if
    /// `beginRestoring()` was never followed by any restore calls at all.
    func finishRestoring() {
        guard isRestoring else { return }
        isRestoring = false
        suppressPersistToDisk = false
        for key in pendingBudgetRegistrations {
            guard let data = dataByKey[key] else { continue }
            budget.register(owner: self, imageId: key.imageId, version: key.version, bytes: data.count)
        }
        pendingBudgetRegistrations.removeAll(keepingCapacity: false)
        enforceLocalBounds()
        if restoreAdvertisedChanged {
            imageAvailabilityGeneration &+= 1
            restoreAdvertisedChanged = false
        }
    }
}
