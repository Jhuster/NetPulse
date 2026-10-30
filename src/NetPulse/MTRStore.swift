import Foundation
import AppKit
import Darwin

@MainActor final class MTRStore: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published private(set) var imported = false
    @Published private(set) var samples: [MTRSample] = []
    @Published private(set) var target = ""
    @Published private(set) var targetIP = ""
    @Published private(set) var logURL: URL?
    @Published private(set) var state = "idle"
    @Published private(set) var message = "目标约每秒采样；逐跳按轮次观察，中间无回复不等于转发丢包。"
    @Published private(set) var round = 0
    @Published private(set) var segment = 1
    @Published private(set) var roundTTL = 0
    @Published private(set) var raw = ""
    @Published var selectedTTL: Int?
    @Published var selectedSegment = 1
    @Published var span = 60.0
    @Published var follow = true
    @Published var endDate = Date()
    var onChange: (() -> Void)?
    var onAddress: ((String) -> Void)?
    var location: ((String) -> GeoLocation?)?
    var roundInterval = 5.0
    var roundBudget = 35.0
    var hopLimit = 30
    var logRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NetPulse")
    private(set) var process: Process?
    private var pingProcess: Process?
    private var timer: Timer?
    private var cleanupTask: Task<Void, Never>?
    private(set) var token = UUID()
    private var logFailed = false
    private var serial = 0
    private var pending = ""
    private var roundBytes = 0
    private var roundTerminated = false
    private var changedInRound = false
    private var known: [Int: String] = [:]
    private var nextRound = 0.0
    private var lastTick = 0.0
    private var started = Date()
    private var clockOrigin = Date()
    private var uptimeOrigin = ProcessInfo.processInfo.systemUptime
    private var csv: FileHandle?
    private var diagnostic: FileHandle?
    private var metadata: [String: String] = [:]
    private var sessionID = UUID()
    private let traceExecutable: URL
    private let traceArguments: [String]?
    private let pingExecutable: URL
    private let pingArguments: [String]?
    init(traceExecutable: URL = URL(fileURLWithPath: "/usr/sbin/traceroute"), traceArguments: [String]? = nil,
         pingExecutable: URL = URL(fileURLWithPath: "/sbin/ping"), pingArguments: [String]? = nil) {
        self.traceExecutable = traceExecutable; self.traceArguments = traceArguments
        self.pingExecutable = pingExecutable; self.pingArguments = pingArguments
    }
    private var now: Date { clockOrigin.addingTimeInterval(ProcessInfo.processInfo.systemUptime - uptimeOrigin) }
    var hasSession: Bool { logURL != nil }
    var segments: [Int] { Array(Set(samples.map(\.segment))).sorted() }
    var window: [MTRSample] { samples.filter { $0.segment == selectedSegment && $0.date > endDate.addingTimeInterval(-span) && $0.date <= endDate } }
    var targetStats: MTRStats { MTRStats(samples: window.filter { $0.kind == "target" }) }
    var rows: [MTRHopRow] {
        let grouped = Dictionary(grouping: window.filter { $0.kind == "hop" }, by: \.ttl)
        return grouped.keys.sorted().map { MTRHopRow(id: $0, stats: MTRStats(samples: grouped[$0]!)) }
    }
    var targetLoss: [MTRLossPoint] {
        let points = window.filter { $0.kind == "target" }
        let groups = Dictionary(grouping: points) { Int($0.date.timeIntervalSince1970 / 5) }
        return groups.keys.sorted().compactMap { key in
            MTRStats(samples: groups[key]!).loss.map { MTRLossPoint(id: key, date: Date(timeIntervalSince1970: Double(key) * 5), loss: $0) }
        }
    }
    var historyRange: ClosedRange<Double> {
        let lower = samples.first?.date.timeIntervalSince1970 ?? endDate.timeIntervalSince1970
        let upper = samples.last?.date.timeIntervalSince1970 ?? lower
        return lower...max(lower + 0.001, upper)
    }
    func chooseSegment(_ value: Int) {
        selectedSegment = value; follow = false
        if let last = samples.last(where: { $0.segment == value }) { endDate = last.date }
    }
    func browse(_ date: Date) {
        follow = false; endDate = date
        if let p = samples.last(where: { $0.date <= date }) { selectedSegment = p.segment }
    }
    func live() { follow = true; selectedSegment = segment; endDate = now }
    func begin(_ address: String) {
        guard !running, !stopping, !imported else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.count <= 253, address.range(of: "^[A-Za-z0-9][A-Za-z0-9.\\-]*$", options: .regularExpression) != nil else { message = "请输入域名或 IPv4 地址"; return }
        guard !hasSession || address == target else { message = "请新建测试后更换目标"; return }
        logFailed = false
        clockOrigin = max(Date(), samples.last?.date ?? .distantPast); uptimeOrigin = ProcessInfo.processInfo.systemUptime
        if !hasSession {
            target = address; started = now; sessionID = UUID(); serial = 0; round = 0; segment = 1; samples = []; known = [:]
            metadata = ["Session": sessionID.uuidString, "Target": address, "Target-IP": "", "Started-At": CSVLog.timestamp(started), "App-Version": "0.1.0", "Protocol": "ICMP IPv4", "Method": "system traceroute TTL sweeps + independent target ping", "Round-Interval-Seconds": String(roundInterval), "Round-Budget-Seconds": String(roundBudget), "Max-TTL": String(hopLimit), "Samples-Per-TTL-Per-Round": "1", "Target-Interval-Seconds": "1", "Status": "running", "Timestamp": "monotonic anchored wall time; observed completion", "Reply-Ratio": "per TTL; error/cancellation excluded; no reply is not forwarding loss", "RTT-Unit": "ms", "P95": "nearest rank"]
            do {
                let dir = logRoot.appendingPathComponent("mtr-\(sessionID.uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("mtr.csv")
                try Data(MTRCSV.header(metadata).utf8).write(to: file, options: .atomic)
                csv = try FileHandle(forWritingTo: file); try csv?.seekToEnd()
                let diag = dir.appendingPathComponent("mtr-diagnostics.txt"); try Data().write(to: diag)
                diagnostic = try FileHandle(forWritingTo: diag); logURL = file
            } catch { state = "failed"; message = "MTR 日志创建失败：\(error.localizedDescription)"; close(); onChange?(); return }
        } else {
            do {
                csv = try FileHandle(forWritingTo: logURL!); try csv?.seekToEnd()
                diagnostic = try FileHandle(forWritingTo: logURL!.deletingLastPathComponent().appendingPathComponent("mtr-diagnostics.txt")); try diagnostic?.seekToEnd()
            } catch { state = "failed"; message = "无法继续写入会话日志：\(error.localizedDescription)"; close(); onChange?(); return }
            newSegment("暂停后继续"); event("resume")
        }
        guard !logFailed else { close(); onChange?(); return }
        token = UUID(); running = true; state = "running"; follow = true; selectedSegment = segment
        writeMetadata(["Status": state, "Ended-At": ""]); nextRound = 0; lastTick = ProcessInfo.processInfo.systemUptime
        message = "持续观察中 · 目标约 1 秒 / 次；逐跳每轮至少 \(Int(roundInterval)) 秒，静默路径可能更慢"
        guard running else { return }
        tick(); guard running else { return }; timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        onChange?()
    }
    private func tick() {
        guard running else { return }
        let clock = ProcessInfo.processInfo.systemUptime
        if clock - lastTick > 5 { newSegment("休眠或采样调度空档"); shutdown(status: "paused", message: "检测到采样调度空档，已暂停并丢弃在途结果；点击继续开启新段。"); return }
        lastTick = clock
        if follow { endDate = now; selectedSegment = segment }
        if process == nil && clock >= nextRound { launchRound() }
        if !targetIP.isEmpty && pingProcess == nil { launchTarget() }
    }
    private func launchRound() {
        round += 1; roundTTL = 0; changedInRound = false; pending = ""; roundBytes = 0; roundTerminated = false
        nextRound = ProcessInfo.processInfo.systemUptime + roundInterval
        let p = Process(); let pipe = Pipe(); let generation = token; let currentRound = round
        p.executableURL = traceExecutable
        p.arguments = traceArguments ?? ["-I", "-n", "-m", String(hopLimit), "-q", "1", "-w", "1", "-z", "100", targetIP.isEmpty ? target : targetIP]
        p.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardOutput = pipe; p.standardError = pipe; process = p
        do { try p.run() } catch { process = nil; fail("无法启动逐跳探测：\(error.localizedDescription)"); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                DispatchQueue.main.async { [weak self] in self?.receive(data, generation: generation, round: currentRound) }
            }
            p.waitUntilExit()
            DispatchQueue.main.async { [weak self] in self?.finishRound(p.terminationStatus, generation: generation, round: currentRound) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + roundBudget) { [weak self] in
            guard let self, self.running, self.token == generation, self.round == currentRound, self.process === p else { return }
            self.roundTerminated = true
            if p.isRunning { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
    }
    func receive(_ data: Data, generation: UUID, round: Int) {
        guard running, token == generation, self.round == round else { return }
        roundBytes += data.count
        guard roundBytes <= 1_000_000 else { fail("逐跳系统输出超过 1 MB 上限"); return }
        let text = String(decoding: data, as: UTF8.self)
        raw += text; if raw.count > 100_000 { raw = String(raw.suffix(100_000)) }
        do { try diagnostic?.write(contentsOf: Data("[\(CSVLog.timestamp(now)) round=\(round)] \(text)".utf8)); try diagnostic?.synchronize() }
        catch { fail("原始诊断日志写入失败：\(error.localizedDescription)"); return }
        pending += text
        while let end = pending.firstIndex(of: "\n") { let line = String(pending[..<end]); pending.removeSubrange(...end); consume(line) }
        onChange?()
    }
    func consume(_ line: String) {
        guard running else { return }
        if let ip = routeTargetIP(line) {
            if targetIP.isEmpty { targetIP = ip; writeMetadata(["Target-IP": ip]); onAddress?(ip) }
            else if ip != targetIP { fail("目标解析地址改变，请新建测试"); return }
        }
        guard let hop = parseRouteHop(line), hop.id <= hopLimit else { return }
        roundTTL = hop.id
        for p in hop.probes {
            let ip = p.address ?? ""
            if p.rtt != nil, !ip.isEmpty {
                if let previous = known[hop.id], previous != ip, !changedInRound {
                    newSegment("第 \(hop.id) 跳回复地址改变：可能为路径变化或多路径"); changedInRound = true
                }
                known[hop.id] = ip
            }
            let place = p.address.flatMap { location?($0) }
            append(kind: "hop", ttl: hop.id, address: ip, rtt: p.rtt, outcome: p.rtt == nil ? "timeout" : "reply", annotation: p.annotation, place: place)
        }
    }
    private func finishRound(_ exit: Int32, generation: UUID, round: Int) {
        guard running, token == generation, self.round == round else { return }
        if !pending.isEmpty { let line = pending; pending = ""; consume(line) }
        process = nil
        guard running else { return }
        if roundTerminated { event("round_timeout", "轮次超时；未完成探针不计丢包") }
        else if exit != 0 { fail("系统逐跳探测退出码 \(exit)，请查看原始日志"); return }
        else if targetIP.isEmpty { fail("未能解析有效目标 IPv4 地址"); return }
        else { event("round_end") }
        onChange?()
    }
    private func launchTarget() {
        let p = Process(); let pipe = Pipe(); let generation = token; let ip = targetIP
        p.executableURL = pingExecutable; p.arguments = pingArguments ?? ["-n", "-c", "1", "-W", "1000", "-t", "2", ip]
        p.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardOutput = pipe; p.standardError = pipe; pingProcess = p
        do { try p.run() } catch { pingProcess = nil; fail("无法启动目标 Ping：\(error.localizedDescription)"); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let text = String(decoding: data.prefix(65_536), as: UTF8.self)
            let probe = parsePing(text, id: 0, date: Date(), elapsed: 0, exit: p.terminationStatus)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.token == generation, self.pingProcess === p else { return }
                self.pingProcess = nil
                do { try self.diagnostic?.write(contentsOf: Data("[\(CSVLog.timestamp(self.now)) target] \(text)".utf8)); try self.diagnostic?.synchronize() }
                catch { self.fail("目标原始日志写入失败：\(error.localizedDescription)"); return }
                let status = ["reply", "timeout"].contains(probe.status) ? probe.status : "error"
                self.append(kind: "target", address: status == "reply" ? ip : "", rtt: probe.rtt, outcome: status, annotation: status == "error" ? "系统 Ping 错误" : "")
                self.onChange?()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if p.isRunning { p.terminate() }; DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } } }
    }
    private func append(kind: String, ttl: Int = 0, address: String = "", rtt: Double? = nil, outcome: String, annotation: String = "", place: GeoLocation? = nil) {
        let sample = MTRSample(id: serial, date: now, segment: segment, round: round, kind: kind, ttl: ttl, address: address, rtt: rtt, outcome: outcome, annotation: annotation, country: place?.country ?? "", province: place?.province ?? "", source: place?.source ?? "")
        serial += 1; samples.append(sample)
        trim()
        if follow { selectedSegment = segment; endDate = sample.date }
        do { try csv?.write(contentsOf: Data(MTRCSV.row(sample).utf8)); try csv?.synchronize() }
        catch { logFailed = true; if running { fail("MTR CSV 写入失败：\(error.localizedDescription)") } else { message = "MTR CSV 写入失败：\(error.localizedDescription)"; state = "failed" } }
    }
    private func trim() {
        if let last = samples.last { samples.removeAll { last.date.timeIntervalSince($0.date) > 7200 } }
        if samples.count > 60_000 { samples.removeFirst(samples.count - 60_000) }
    }
    private func event(_ name: String, _ note: String = "") { append(kind: "event", outcome: name, annotation: note) }
    private func newSegment(_ reason: String) {
        segment += 1; known = [:]; message = "新路径段 \(segment) · \(reason)；等待后续轮次补齐"
        event("segment", reason)
        if running && !targetIP.isEmpty { onAddress?(targetIP) }
    }
    func updateContext(_ values: [String: String]) { guard hasSession, !imported else { return }; writeMetadata(values) }
    private func writeMetadata(_ values: [String: String]) {
        let changed = values.filter { metadata[$0.key] != $0.value }; metadata.merge(values) { _, b in b }
        guard !changed.isEmpty else { return }
        do { try csv?.write(contentsOf: Data(MTRCSV.meta(changed).utf8)); try csv?.synchronize() }
        catch { logFailed = true; if running { fail("MTR 元信息写入失败：\(error.localizedDescription)") } else { message = "MTR 元信息写入失败：\(error.localizedDescription)"; state = "failed" } }
    }
    func pause() { shutdown(status: "paused", message: "已暂停并保留历史，继续时开启新路径段。") }
    private func fail(_ message: String) { shutdown(status: "failed", message: message) }
    private func shutdown(status: String, message: String) {
        guard running else { return }
        running = false; stopping = true; state = status; self.message = message
        timer?.invalidate(); timer = nil
        let processes = [process, pingProcess].compactMap { $0 }; let generation = token
        for p in processes where p.isRunning { p.terminate() }
        // Logging failures must not recursively attempt to append another event.
        if !message.contains("写入失败") { event(status == "paused" ? "pause" : "failed", message) }
        writeMetadata(["Status": status, "Ended-At": CSVLog.timestamp(now)])
        close(); onChange?()
        cleanupTask = Task { [weak self] in
            await Task.detached {
                let limit = ProcessInfo.processInfo.systemUptime + 1.5
                while processes.contains(where: \.isRunning) && ProcessInfo.processInfo.systemUptime < limit { try? await Task.sleep(nanoseconds: 30_000_000) }
                for p in processes { if p.isRunning { kill(p.processIdentifier, SIGKILL) }; p.waitUntilExit() }
            }.value
            guard let self, self.token == generation else { return }
            self.process = nil; self.pingProcess = nil; self.stopping = false; self.cleanupTask = nil; self.onChange?()
        }
    }
    func stopAndWait() async { pause(); await cleanupTask?.value }
    private func close() { try? csv?.close(); try? diagnostic?.close(); csv = nil; diagnostic = nil }
    func reset() {
        token = UUID(); timer?.invalidate(); timer = nil
        for p in [process, pingProcess].compactMap({ $0 }) where p.isRunning { p.terminate(); kill(p.processIdentifier, SIGKILL) }
        cleanupTask?.cancel(); cleanupTask = nil; process = nil; pingProcess = nil; close()
        running = false; stopping = false; imported = false; samples = []; target = ""; targetIP = ""; logURL = nil
        state = "idle"; serial = 0; round = 0; segment = 1; selectedSegment = 1; selectedTTL = nil; known = [:]; raw = ""; pending = ""; metadata = [:]
        message = "目标约每秒采样；逐跳按轮次观察，中间无回复不等于转发丢包。"
    }
    static func read(_ file: URL) throws -> MTRArchive {
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 50_000_000 else { throw CocoaError(.fileReadTooLarge) }
        return try MTRCSV.decode(String(contentsOf: file, encoding: .utf8))
    }
    func load(_ archive: MTRArchive, from file: URL) {
        reset(); metadata = archive.metadata; target = metadata["Target"]!; targetIP = metadata["Target-IP"] ?? ""; state = metadata["Status"]!
        samples = archive.samples; trim(); segment = samples.last?.segment ?? 1; selectedSegment = segment; round = samples.last?.round ?? 0
        endDate = samples.last?.date ?? Date(); follow = false; imported = true; logURL = file
        message = "离线回放 · 最近两小时 / 最多 60,000 条记录 · \(archive.samples.count) 条原始记录" + (["running", "pausing"].contains(state) ? "；文件未正常收尾" : "")
        if let note = metadata["Data-Note"], !note.isEmpty { message += " · " + String(note.prefix(200)) }
        onChange?()
    }
}
