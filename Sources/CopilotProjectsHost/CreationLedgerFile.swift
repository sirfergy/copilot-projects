import Foundation

enum CreationLedgerFile {
    private enum PersistenceError: LocalizedError {
        case couldNotCreateTemporaryFile(String)
        case couldNotReplaceLedger(path: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateTemporaryFile(let path):
                return "Could not create temporary creation ledger at \(path)"
            case .couldNotReplaceLedger(let path, let code):
                return "Could not replace creation ledger at \(path) (errno \(code))"
            }
        }
    }

    static func read(from url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            let isMissing =
                (nsError.domain == NSCocoaErrorDomain
                    && nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
            if isMissing { return nil }
            throw error
        }
    }

    /// Keep the temporary file private from its creation through the atomic rename.
    static func write(_ data: Data, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = directoryURL
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw PersistenceError.couldNotCreateTemporaryFile(temporaryURL.path)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if rename(temporaryURL.path, url.path) != 0 {
                throw PersistenceError.couldNotReplaceLedger(path: url.path, code: errno)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}
