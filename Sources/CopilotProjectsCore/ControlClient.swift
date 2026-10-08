import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ControlClientError: Error, CustomStringConvertible {
    case cannotConnect(String)
    case io(String)
    case decode(String)

    public var description: String {
        switch self {
        case .cannotConnect(let m): return "cannot connect: \(m)"
        case .io(let m): return "io error: \(m)"
        case .decode(let m): return "decode error: \(m)"
        }
    }
}

/// Minimal blocking client for the control socket: connect, send one JSON line,
/// read one JSON line, close.
public struct ControlClient: Sendable {
    public let socketPath: String
    /// How long a read or write may wait for the app.
    public let timeout: TimeInterval

    public init(socketPath: String = Paths.socketPath, timeout: TimeInterval = 3) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw ControlClientError.cannotConnect("socket() failed (errno \(errno))")
        }
        defer { close(fd) }
        guard SocketOptions.suppressSigPipe(on: fd) else {
            throw ControlClientError.cannotConnect("SO_NOSIGPIPE failed (errno \(errno))")
        }

        // Bound every phase so a slow/hung app can never block the caller. This
        // client runs inside the Copilot status hook; a hook that blocks past its
        // timeout is treated as an error that DENIES the agent's tool call. Keeping
        // it synchronous (not backgrounded) preserves status ordering — a
        // running→waiting transition can't land out of order — while the timeout
        // prevents a hang.
        let bounded = max(timeout, 0.001)
        var tv = timeval(
            tv_sec: Int(bounded),
            tv_usec: Int32((bounded - Double(Int(bounded))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count >= capacity {
            throw ControlClientError.cannotConnect("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() {
                    dst[i] = CChar(bitPattern: b)
                }
                dst[pathBytes.count] = 0
            }
        }

        // Bound connect() too: SO_RCVTIMEO/SO_SNDTIMEO only cover read/write, so a
        // blocking connect to an app whose accept loop is briefly stalled would
        // hang here unbounded — and this client runs inside the preToolUse status
        // hook, where blocking past the hook timeout makes the CLI DENY the agent's
        // tool call. Connect non-blocking, wait at most ~2s for completion, then
        // restore blocking mode so the SO_*TIMEO above govern the read/write.
        let savedFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, savedFlags | O_NONBLOCK)

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pfd, nfds_t(1), 2000)   // wait up to 2s for writability
                if pr <= 0 {
                    throw ControlClientError.cannotConnect("connect timed out (\(socketPath))")
                }
                var soErr: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                if soErr != 0 {
                    throw ControlClientError.cannotConnect("connect failed (\(socketPath), errno \(soErr))")
                }
            } else {
                throw ControlClientError.cannotConnect(
                    "is Copilot Projects running? (\(socketPath), errno \(errno))")
            }
        }
        _ = fcntl(fd, F_SETFL, savedFlags)   // back to blocking; SO_*TIMEO now apply

        let payload = try Wire.encodeLine(request)
        try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while off < raw.count {
                let n = write(fd, base + off, raw.count - off)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { throw ControlClientError.io("write failed (errno \(errno))") }
                off += n
            }
        }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            if n < 0 { throw ControlClientError.io("read failed (errno \(errno))") }
            if n == 0 { break }
            response.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }

        let line: Data
        if let nl = response.firstIndex(of: 0x0A) {
            line = response.subdata(in: response.startIndex..<nl)
        } else {
            line = response
        }
        if line.isEmpty {
            throw ControlClientError.io("empty response")
        }
        do {
            return try Wire.decode(ControlResponse.self, from: line)
        } catch {
            throw ControlClientError.decode("\(error)")
        }
    }
}
