import Foundation

/// Wire contract for fetching a captured Kitty inline image's PNG bytes. Mirrors
/// `RemoteSessionContract`'s style: a path constant shared by the host and the
/// client, plus the query parameters (`s`ession, `i`mage id, `v`ersion) the host
/// requires. Additive and backward compatible: an older host simply doesn't route
/// this path and a client gets a 404, so it can treat images as unsupported.
public enum RemoteTerminalImageContract {
    /// Path (relative to the gateway base, no leading slash) a client GETs with
    /// `?s=<sessionId>&i=<imageId>&v=<contentVersion>` to fetch a captured image's
    /// exact PNG bytes.
    public static let path = "terminal-image"
}

/// A rectangular region of the emitted `RemoteTerminalScreen.lines` grid where a
/// Kitty Unicode-placeholder image should be rendered. `line`/`column` are
/// relative to the emitted screen (i.e. index into `lines`, not an absolute
/// scroll-invariant row), so they are only valid for the screen they were
/// attached to and must be recomputed whenever a new screen is captured.
/// `imageId`/`contentVersion` identify the exact retained PNG bytes to fetch via
/// `RemoteTerminalImageContract.path`.
public struct RemoteTerminalImagePlacement: Codable, Equatable, Sendable {
    public let imageId: UInt32
    public let contentVersion: UInt64
    /// Decimal representation of `contentVersion` for clients whose native
    /// number type cannot exactly represent every UInt64 (notably JavaScript).
    /// Additive/backward-compatible: native clients continue using the numeric
    /// field, while those clients use this exact string for cache keys and URLs.
    public let contentVersionText: String?
    public let line: Int
    public let column: Int
    public let rows: Int
    public let columns: Int

    public init(
        imageId: UInt32,
        contentVersion: UInt64,
        line: Int,
        column: Int,
        rows: Int,
        columns: Int
    ) {
        self.imageId = imageId
        self.contentVersion = contentVersion
        self.contentVersionText = String(contentVersion)
        self.line = line
        self.column = column
        self.rows = rows
        self.columns = columns
    }
}
