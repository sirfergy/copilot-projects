import CopilotProjectsCore
import CopilotProjectsProtocol
import Darwin
import Foundation

public enum HostHealthEvaluator {
    public static let diskQuantizationBytes: Int64 = 100_000_000
    public static let latencyQuantizationMilliseconds: Int = 5

    public static let criticalCPUThreshold = 90
    public static let warningCPUThreshold = 75
    public static let criticalMemoryThreshold = 90
    public static let warningMemoryThreshold = 80
    public static let criticalDiskAvailableBytes: Int64 = 5_000_000_000
    public static let warningDiskAvailableBytes: Int64 = 15_000_000_000
    public static let warningLatencyMilliseconds = 500

    public static func quantizeDiskBytes(_ bytes: Int64?) -> Int64? {
        guard let bytes, bytes >= 0 else { return nil }
        return (bytes / diskQuantizationBytes) * diskQuantizationBytes
    }

    public static func quantizeLatencyMilliseconds(_ milliseconds: Int?) -> Int? {
        guard let milliseconds, milliseconds >= 0 else { return nil }
        return (milliseconds / latencyQuantizationMilliseconds) * latencyQuantizationMilliseconds
    }

    public static func clampPercent(_ value: Int?) -> Int? {
        guard let value else { return nil }
        return min(100, max(0, value))
    }

    public static func evaluate(
        reachable: Bool = true,
        cpuUsagePercent: Int? = nil,
        memoryUsagePercent: Int? = nil,
        diskAvailableBytes: Int64? = nil,
        latencyMilliseconds: Int? = nil
    ) -> (level: RemoteHostHealthLevel, statusSummary: String?) {
        guard reachable else {
            return (.critical, "Unreachable")
        }

        let cpu = clampPercent(cpuUsagePercent)
        let memory = clampPercent(memoryUsagePercent)
        let disk = diskAvailableBytes
        let latency = latencyMilliseconds

        var criticalReasons: [String] = []
        if let cpu, cpu >= criticalCPUThreshold {
            criticalReasons.append("High CPU (\(cpu)%)")
        }
        if let memory, memory >= criticalMemoryThreshold {
            criticalReasons.append("High memory (\(memory)%)")
        }
        if let disk, disk < criticalDiskAvailableBytes {
            criticalReasons.append("Low disk")
        }
        if !criticalReasons.isEmpty {
            return (.critical, criticalReasons.joined(separator: ", "))
        }

        var warningReasons: [String] = []
        if let cpu, cpu >= warningCPUThreshold {
            warningReasons.append("High CPU (\(cpu)%)")
        }
        if let memory, memory >= warningMemoryThreshold {
            warningReasons.append("High memory (\(memory)%)")
        }
        if let disk, disk < warningDiskAvailableBytes {
            warningReasons.append("Low disk")
        }
        if let latency, latency >= warningLatencyMilliseconds {
            warningReasons.append("High latency (\(latency) ms)")
        }
        if !warningReasons.isEmpty {
            return (.warning, warningReasons.joined(separator: ", "))
        }

        return (.healthy, nil)
    }

    public static func makeHealth(
        host: RemoteHostInfo,
        reachable: Bool = true,
        cpuUsagePercent: Int? = nil,
        memoryUsagePercent: Int? = nil,
        diskAvailableBytes: Int64? = nil,
        diskTotalBytes: Int64? = nil,
        latencyMilliseconds: Int? = nil
    ) -> RemoteHostHealth {
        let clampedCPU = clampPercent(cpuUsagePercent)
        let clampedMemory = clampPercent(memoryUsagePercent)
        let quantizedAvailable = quantizeDiskBytes(diskAvailableBytes)
        let quantizedTotal = quantizeDiskBytes(diskTotalBytes)
        let quantizedLatency = quantizeLatencyMilliseconds(latencyMilliseconds)
        let evaluation = evaluate(
            reachable: reachable,
            cpuUsagePercent: clampedCPU,
            memoryUsagePercent: clampedMemory,
            diskAvailableBytes: quantizedAvailable,
            latencyMilliseconds: quantizedLatency
        )
        return RemoteHostHealth(
            hostId: host.id,
            displayName: host.displayName,
            isLocal: host.isLocal,
            reachable: reachable,
            level: evaluation.level,
            cpuUsagePercent: reachable ? clampedCPU : nil,
            memoryUsagePercent: reachable ? clampedMemory : nil,
            diskAvailableBytes: reachable ? quantizedAvailable : nil,
            diskTotalBytes: reachable ? quantizedTotal : nil,
            latencyMilliseconds: reachable ? quantizedLatency : nil,
            statusSummary: evaluation.statusSummary
        )
    }
}

public struct CPULoadTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var active: UInt64 { user &+ system &+ nice }
    public var total: UInt64 { active &+ idle }
}

public final class HostHealthMonitor: @unchecked Sendable {
    public typealias RemoteHostProbe = @Sendable (RemoteHostInfo) async -> RemoteHostHealth

    private let lock = NSLock()
    private var previousCPUTicks: CPULoadTicks?
    private var lastCPUPercent: Int?
    private var previousRemoteCPUTicks: [String: (active: UInt64, total: UInt64)] = [:]
    private var lastRemoteCPUPercent: [String: Int] = [:]
    private let remoteProbe: RemoteHostProbe?

    public nonisolated init(remoteProbe: RemoteHostProbe? = nil) {
        self.remoteProbe = remoteProbe
    }

    public func sampleLocalHost(host: RemoteHostInfo = .local) -> RemoteHostHealth {
        let cpu = sampleLocalCPUPercent()
        let memory = Self.sampleLocalMemoryPercent()
        let disk = Self.sampleLocalDiskBytes()
        return HostHealthEvaluator.makeHealth(
            host: host,
            reachable: true,
            cpuUsagePercent: cpu,
            memoryUsagePercent: memory,
            diskAvailableBytes: disk.available,
            diskTotalBytes: disk.total,
            latencyMilliseconds: nil
        )
    }

    public static let maximumConcurrentRemoteProbes = 4

    public func sampleAll(
        hosts: [RemoteHostInfo],
        localHealth preSampledLocal: RemoteHostHealth? = nil
    ) async -> [RemoteHostHealth] {
        let targetHosts = hosts.isEmpty ? [RemoteHostInfo.local] : hosts
        let localHost = targetHosts.first(where: \.isLocal) ?? .local
        let localHealth: RemoteHostHealth
        if let preSampledLocal {
            localHealth = preSampledLocal
        } else {
            localHealth = await Task.detached(priority: .utility) { [self] in
                self.sampleLocalHost(host: localHost)
            }.value
        }
        let remoteHosts = targetHosts.filter { !$0.isLocal }
        guard !remoteHosts.isEmpty else {
            return [localHealth]
        }

        let customProbe = remoteProbe
        let remoteResults = await withTaskGroup(of: (Int, RemoteHostHealth).self) { group in
            var nextIndex = 0
            let initialCount = min(Self.maximumConcurrentRemoteProbes, remoteHosts.count)
            for _ in 0 ..< initialCount {
                let index = nextIndex
                let host = remoteHosts[index]
                nextIndex += 1
                group.addTask { [self] in
                    if let customProbe {
                        return (index, await customProbe(host))
                    }
                    return (index, await self.probeRemoteSSHHost(host))
                }
            }
            var collected: [(Int, RemoteHostHealth)] = []
            collected.reserveCapacity(remoteHosts.count)
            for await item in group {
                collected.append(item)
                if nextIndex < remoteHosts.count {
                    let index = nextIndex
                    let host = remoteHosts[index]
                    nextIndex += 1
                    group.addTask { [self] in
                        if let customProbe {
                            return (index, await customProbe(host))
                        }
                        return (index, await self.probeRemoteSSHHost(host))
                    }
                }
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var results: [RemoteHostHealth] = []
        results.reserveCapacity(targetHosts.count)
        var remoteIterator = remoteResults.makeIterator()
        var includedLocal = false
        for host in targetHosts {
            if host.isLocal {
                if !includedLocal {
                    results.append(localHealth)
                    includedLocal = true
                }
            } else if let nextRemote = remoteIterator.next() {
                results.append(nextRemote)
            }
        }
        if !includedLocal {
            results.insert(localHealth, at: 0)
        }
        return results
    }

    // MARK: - Local Mac Probes

    public static func cpuUsagePercent(previous: CPULoadTicks?, current: CPULoadTicks) -> Int? {
        if let previous,
           current.total > previous.total,
           current.active >= previous.active {
            let activeDelta = current.active - previous.active
            let totalDelta = current.total - previous.total
            if activeDelta <= totalDelta {
                let raw = Int((Double(activeDelta) / Double(totalDelta) * 100.0).rounded())
                return HostHealthEvaluator.clampPercent(raw)
            }
        }
        guard current.total > 0, current.active <= current.total else { return nil }
        let raw = Int((Double(current.active) / Double(current.total) * 100.0).rounded())
        return HostHealthEvaluator.clampPercent(raw)
    }

    private func sampleLocalCPUPercent() -> Int? {
        guard let current = Self.readLocalCPULoadTicks() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let previous = previousCPUTicks
        previousCPUTicks = current
        if let previous, current.total == previous.total, let lastCPUPercent {
            return lastCPUPercent
        }
        let computed = Self.cpuUsagePercent(previous: previous, current: current)
        lastCPUPercent = computed
        return computed
    }

    public static func readLocalCPULoadTicks() -> CPULoadTicks? {
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(
            hostPort,
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )
        guard result == KERN_SUCCESS, let cpuInfo else { return nil }
        defer {
            let byteCount = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), byteCount)
        }

        var ticks = CPULoadTicks()
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0 ..< Int(numCPUs) {
            let base = cpu * stride
            ticks.user &+= UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)]))
            ticks.system &+= UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)]))
            ticks.idle &+= UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)]))
            ticks.nice &+= UInt64(UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)]))
        }
        return ticks
    }

    public static func sampleLocalMemoryPercent() -> Int? {
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(hostPort, HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        let activePages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let usedBytes = activePages * pageSize
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        guard physicalMemory > 0 else { return nil }
        let raw = Int((Double(usedBytes) / Double(physicalMemory) * 100.0).rounded())
        return HostHealthEvaluator.clampPercent(raw)
    }

    public static func sampleLocalDiskBytes(
        homeDirectoryPath: String = NSHomeDirectory()
    ) -> (available: Int64?, total: Int64?) {
        let url = URL(fileURLWithPath: homeDirectoryPath)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
        ]) else {
            return (nil, nil)
        }
        let available: Int64?
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = Int64(important)
        } else if let standard = values.volumeAvailableCapacity {
            available = Int64(standard)
        } else {
            available = nil
        }
        let total = values.volumeTotalCapacity.map(Int64.init)
        return (available, total)
    }

    // MARK: - Remote SSH Probe

    private static let sshRemoteProbeScript = """
    df -Pk . | tail -n 1; \
    if [ -r /proc/meminfo ]; then \
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2; haveAvailable=1} END{if(t>0 && haveAvailable && a>=0) printf "MEM %d\\n", int(((t-a)*100 + t/2)/t)}' /proc/meminfo 2>/dev/null || true; \
    awk '/^cpu /{u=$2+$3+$4+$7+$8+$9; t=u+$5+$6; if(t>0) printf "CPU_TICKS %.0f %.0f\\n", u, t}' /proc/stat 2>/dev/null || true; \
    else \
    vm_stat 2>/dev/null | awk -v m="$(sysctl -n hw.memsize 2>/dev/null)" '/page size of/{p=$8} /Pages active:/{a=$3} /Pages wired down:/{w=$4} /Pages occupied by compressor:/{c=$5} END{gsub(/\\./,"",a);gsub(/\\./,"",w);gsub(/\\./,"",c);u=(a+w+c)*(p>0?p:4096);if(m>0&&u>=0) printf "MEM %d\\n", int((u*100+m/2)/m)}' || true; \
    ps -A -o %cpu 2>/dev/null | awk -v n="$(sysctl -n hw.logicalcpu 2>/dev/null)" 'NR>1{s+=$1} END{if(n>0) printf "CPU %d\\n", int(s/n+0.5)}' || true; \
    fi
    """

    public struct ParsedSSHProbeOutput: Sendable, Equatable {
        public let diskAvailableBytes: Int64?
        public let diskTotalBytes: Int64?
        public let cpuUsagePercent: Int?
        public let memoryUsagePercent: Int?
        public let cpuTicks: (active: UInt64, total: UInt64)?

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.diskAvailableBytes == rhs.diskAvailableBytes
                && lhs.diskTotalBytes == rhs.diskTotalBytes
                && lhs.cpuUsagePercent == rhs.cpuUsagePercent
                && lhs.memoryUsagePercent == rhs.memoryUsagePercent
                && lhs.cpuTicks?.active == rhs.cpuTicks?.active
                && lhs.cpuTicks?.total == rhs.cpuTicks?.total
        }
    }

    public static func parseSSHProbeOutput(
        _ output: String
    ) -> ParsedSSHProbeOutput {
        var diskAvailableBytes: Int64?
        var diskTotalBytes: Int64?
        var cpuUsagePercent: Int?
        var memoryUsagePercent: Int?
        var cpuTicks: (active: UInt64, total: UInt64)?

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)

            if tokens.count == 3,
               tokens[0] == "CPU_TICKS",
               let active = UInt64(tokens[1]),
               let total = UInt64(tokens[2]),
               total > 0,
               active <= total {
                cpuTicks = (active, total)
                if cpuUsagePercent == nil {
                    let raw = Int((Double(active) / Double(total) * 100.0).rounded())
                    cpuUsagePercent = HostHealthEvaluator.clampPercent(raw)
                }
                continue
            }
            if tokens.count == 2, tokens[0] == "CPU", let value = Int(tokens[1]) {
                cpuUsagePercent = HostHealthEvaluator.clampPercent(value)
                continue
            }
            if tokens.count == 2, tokens[0] == "MEM", let value = Int(tokens[1]) {
                memoryUsagePercent = HostHealthEvaluator.clampPercent(value)
                continue
            }
            if diskTotalBytes == nil,
               let percentIndex = tokens.firstIndex(where: {
                   $0.hasSuffix("%") && Int($0.dropLast()) != nil
               }),
               percentIndex >= 3,
               let totalBlocks = Int64(tokens[percentIndex - 3]),
               let availableBlocks = Int64(tokens[percentIndex - 1]),
               totalBlocks >= 0,
               totalBlocks <= Int64.max / 1_024,
               availableBlocks <= Int64.max / 1_024 {
                diskTotalBytes = totalBlocks * 1_024
                diskAvailableBytes = max(0, availableBlocks) * 1_024
            }
        }

        return ParsedSSHProbeOutput(
            diskAvailableBytes: diskAvailableBytes,
            diskTotalBytes: diskTotalBytes,
            cpuUsagePercent: cpuUsagePercent,
            memoryUsagePercent: memoryUsagePercent,
            cpuTicks: cpuTicks
        )
    }

    public func resolveRemoteCPUPercent(
        hostId: String,
        parsed: ParsedSSHProbeOutput
    ) -> Int? {
        guard let current = parsed.cpuTicks else {
            return parsed.cpuUsagePercent
        }
        lock.lock()
        defer { lock.unlock() }
        let previous = previousRemoteCPUTicks[hostId]
        previousRemoteCPUTicks[hostId] = current
        if let previous {
            if current.total == previous.total, let last = lastRemoteCPUPercent[hostId] {
                return last
            }
            if current.total > previous.total,
               current.active >= previous.active,
               current.active - previous.active <= current.total - previous.total {
                let activeDelta = current.active - previous.active
                let totalDelta = current.total - previous.total
                let raw = Int((Double(activeDelta) / Double(totalDelta) * 100.0).rounded())
                let clamped = HostHealthEvaluator.clampPercent(raw)
                if let clamped { lastRemoteCPUPercent[hostId] = clamped }
                return clamped
            }
        }
        let fallback = parsed.cpuUsagePercent
        if let fallback { lastRemoteCPUPercent[hostId] = fallback }
        return fallback
    }

    public func probeRemoteSSHHost(
        _ host: RemoteHostInfo,
        sshExecutablePath: String = "/usr/bin/ssh",
        timeoutSeconds: TimeInterval = 5.0
    ) async -> RemoteHostHealth {
        await Self.probeSSHHost(
            host,
            sshExecutablePath: sshExecutablePath,
            timeoutSeconds: timeoutSeconds,
            resolveCPU: { [weak self] parsed in
                self?.resolveRemoteCPUPercent(hostId: host.id, parsed: parsed) ?? parsed.cpuUsagePercent
            }
        )
    }

    private final class ProbeProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var rootIdentity: ProcessTree.Identity?
        private var cancelled = false
        private var isStopping = false
        private var isDrained = false

        func attach(_ candidate: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                return false
            }
            process = candidate
            return true
        }

        func recordLaunch() {
            lock.lock()
            let pid = process?.processIdentifier ?? 0
            lock.unlock()
            guard pid > 0, let identity = ProcessTree.Identity(pid) else { return }
            lock.lock()
            rootIdentity = identity
            lock.unlock()
        }

        func markDrained() {
            lock.lock()
            isDrained = true
            lock.unlock()
        }

        func cancelIfRequested() {
            lock.lock()
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel {
                cancel()
            }
        }

        private func signalGroup(_ pid: pid_t, _ signal: Int32) {
            lock.lock()
            let root = rootIdentity
            lock.unlock()
            if let current = ProcessTree.Identity(pid), current != root { return }
            kill(-pid, signal)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            guard !isStopping,
                  let running = process,
                  running.processIdentifier > 0 else {
                lock.unlock()
                return
            }
            isStopping = true
            let pid = running.processIdentifier
            lock.unlock()
            let rootRunning = running.isRunning
            let started = rootRunning ? ProcessTree.descendants(of: pid) : []
            if rootRunning { running.terminate() }
            signalGroup(pid, SIGTERM)
            started.forEach { $0.signal(SIGTERM) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) { [self] in
                lock.lock()
                let drained = isDrained
                lock.unlock()
                let stillRunning = !drained && running.isRunning
                var survivors = Set(started)
                if stillRunning {
                    survivors.formUnion(ProcessTree.descendants(of: pid))
                }
                survivors.forEach { $0.signal(SIGKILL) }
                signalGroup(pid, SIGKILL)
                if stillRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    private final class BoundedPipeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int

        init(limit: Int = 65_536) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            if data.count + chunk.count <= limit {
                data.append(chunk)
            } else {
                let combined = data + chunk
                data = Data(combined.suffix(limit))
            }
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    public static func probeSSHHost(
        _ host: RemoteHostInfo,
        sshExecutablePath: String = "/usr/bin/ssh",
        timeoutSeconds: TimeInterval = 5.0,
        resolveCPU: (@Sendable (ParsedSSHProbeOutput) -> Int?)? = nil
    ) async -> RemoteHostHealth {
        let target = (host.sshTarget ?? host.id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.hasPrefix("-") else {
            return HostHealthEvaluator.makeHealth(host: host, reachable: false)
        }

        let box = ProbeProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: sshExecutablePath)
                    process.arguments = [
                        "-o", "BatchMode=yes",
                        "-o", "ConnectTimeout=4",
                        "-o", "ClearAllForwardings=yes",
                        "-o", "ForwardAgent=no",
                        "-o", "PermitLocalCommand=no",
                        "-o", "RemoteCommand=none",
                        target,
                        "/bin/sh -c \(TerminalController.shellSingleQuote(sshRemoteProbeScript))",
                    ]
                    process.standardInput = FileHandle.nullDevice
                    let stdoutPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = FileHandle.nullDevice

                    guard box.attach(process) else {
                        continuation.resume(
                            returning: HostHealthEvaluator.makeHealth(host: host, reachable: false)
                        )
                        return
                    }

                    let stdoutBuffer = BoundedPipeBuffer()
                    let readGroup = DispatchGroup()
                    let readHandle = stdoutPipe.fileHandleForReading
                    readGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { readGroup.leave() }
                        while true {
                            let chunk = (try? readHandle.read(upToCount: 4_096)) ?? nil
                            guard let chunk, !chunk.isEmpty else { break }
                            stdoutBuffer.append(chunk)
                        }
                    }

                    let finishedSemaphore = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in
                        finishedSemaphore.signal()
                    }

                    let start = ContinuousClock.now
                    do {
                        try process.run()
                    } catch {
                        try? stdoutPipe.fileHandleForWriting.close()
                        _ = readGroup.wait(timeout: .now() + 0.2)
                        continuation.resume(
                            returning: HostHealthEvaluator.makeHealth(host: host, reachable: false)
                        )
                        return
                    }

                    box.recordLaunch()
                    box.cancelIfRequested()

                    let waitResult = finishedSemaphore.wait(timeout: .now() + timeoutSeconds)
                    if waitResult == .timedOut {
                        box.cancel()
                        try? readHandle.close()
                        _ = finishedSemaphore.wait(timeout: .now() + 0.5)
                        box.markDrained()
                        continuation.resume(
                            returning: HostHealthEvaluator.makeHealth(host: host, reachable: false)
                        )
                        return
                    }

                    let elapsed = start.duration(to: ContinuousClock.now)
                    let elapsedMs = max(
                        0,
                        Int(elapsed.components.seconds * 1_000)
                            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                    )

                    if readGroup.wait(timeout: .now() + 0.2) == .timedOut {
                        box.cancel()
                        try? readHandle.close()
                    }
                    box.markDrained()
                    let data = stdoutBuffer.snapshot()
                    guard process.terminationStatus == 0 else {
                        continuation.resume(
                            returning: HostHealthEvaluator.makeHealth(host: host, reachable: false)
                        )
                        return
                    }

                    let output = String(data: data, encoding: .utf8) ?? ""
                    let parsed = parseSSHProbeOutput(output)
                    let cpu = resolveCPU?(parsed) ?? parsed.cpuUsagePercent
                    continuation.resume(
                        returning: HostHealthEvaluator.makeHealth(
                            host: host,
                            reachable: true,
                            cpuUsagePercent: cpu,
                            memoryUsagePercent: parsed.memoryUsagePercent,
                            diskAvailableBytes: parsed.diskAvailableBytes,
                            diskTotalBytes: parsed.diskTotalBytes,
                            latencyMilliseconds: elapsedMs
                        )
                    )
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
