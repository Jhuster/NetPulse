import Foundation
import AppKit

@MainActor final class Store: ObservableObject {
    @Published var target = "1.1.1.1"
    @Published var running = false
    @Published var imported = false
    @Published var follow = true
    @Published var samples: [WindowSample] = []
    @Published var notice = "准备就绪 · 输入域名或 IPv4 地址开始探测"
    @Published var logURL: URL?
    @Published var resolved = "—"
    @Published var sent = 0
    @Published var received = 0
    @Published var errors = 0
    @Published var selectedDate: Date?
    @Published var endDate = Date()
    @Published var span: Double = 300
    var activeTarget: String?
    var session = UUID().uuidString
    var start = Date()
    var uptime: Double = 0
    var timer: Timer?
    var sequence = 0
    var logRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NetPulse")
    var handle: FileHandle?
    var csvHandle: FileHandle?
    var pendingWindows: [Int:Int] = [:]
    var lastCSVIndex = -1
    var lastCSVOffset: UInt64 = 0
    var lastCSVRow = ""
    var work: [Int: Process] = [:]
    var generation = UUID()
    var lastTick = 0.0
    let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    var totalLoss: Double? { let n = sent-errors; return n > 0 ? Double(n-received) / Double(n)*100 : nil }
    var recentLoss: LossInterval {
        let end: Int
        if follow && running {
            let boundary = max(0, Int((lastTick - uptime) / 5))
            end = min(boundary, pendingWindows.values.min() ?? boundary)
        } else if follow {
            end = (samples.last?.id ?? -1) + 1
        } else {
            // Offline/history uses whole 5-second windows up to the visible end.
            let boundary = max(0, Int(floor(endDate.timeIntervalSince(start) / 5)))
            end = min(boundary, (samples.last?.id ?? -1) + 1)
        }
        return LossInterval.summarize(samples, endingAt: end)
    }
    var recentLossDetail: String {
        let value = recentLoss
        if value.seconds == 0 { return "等待首个统计窗口完成" }
        return "\(value.seconds)秒 · 丢失 \(value.lost) / 有效 \(value.valid)"
    }
    var domain: ClosedRange<Date> { endDate.addingTimeInterval(-span)...endDate }
    var visible: [WindowSample] { samples.filter { domain.contains($0.date) } }
    var focused: WindowSample? {
        guard let date = selectedDate else { return visible.last }
        return visible.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
    func write(_ type: String, probe: Probe? = nil, message: String? = nil) {
        guard let handle else { return }
        do {
            var text = "[\(CSVLog.timestamp(Date()))] \(type)"
            if let message { text += " \(message)" }
            if let probe { text += " id=\(probe.id) elapsed=\(probe.elapsed) status=\(probe.status) ip=\(probe.ip ?? "unknown") rtt_ms=\(probe.rtt.map(String.init(describing:)) ?? "missing")\n\(probe.raw)" }
            text += "\n"
            try handle.write(contentsOf: Data(text.utf8)); try handle.synchronize()

        } catch {
            notice = "日志写入失败：\(error.localizedDescription)；已停止探测"
            stop(writeEnd: false)
        }
    }
    func flushWindows(force: Bool = false) {
        guard let csvHandle else { return }
        do {
            let elapsed = ProcessInfo.processInfo.systemUptime - uptime
            for w in samples where w.id >= lastCSVIndex {
                guard !pendingWindows.values.contains(w.id), force || (!running || Double(w.id+1)*5 <= elapsed) else { continue }
                let row = CSVLog.row(w)
                if w.id == lastCSVIndex {
                    guard row != lastCSVRow else { continue }
                    try csvHandle.truncate(atOffset: lastCSVOffset)
                    try csvHandle.seek(toOffset: lastCSVOffset)
                } else {
                    lastCSVOffset = try csvHandle.offset()
                }
                try csvHandle.write(contentsOf: Data(row.utf8))
                lastCSVIndex = w.id; lastCSVRow = row
            }
            try csvHandle.synchronize()
        } catch {
            stop(writeEnd: false); notice = "CSV 日志写入失败：\(error.localizedDescription)；已停止探测"
        }
    }
    func begin() {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 253, t.first != "-", t.range(of: "^[A-Za-z0-9][A-Za-z0-9.\\-]*$", options: .regularExpression) != nil else {
            notice = "请输入有效域名或 IPv4 地址（不包含协议、端口或路径）"; return
        }
        if imported { notice = "请先新建会话，再开始探测"; return }
        if handle != nil && activeTarget != t { reset() }
        target = t
        if handle == nil {
            session = UUID().uuidString; activeTarget = t; start = Date(); uptime = ProcessInfo.processInfo.systemUptime
            do {
                let dir = logRoot.appendingPathComponent(session)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("session.csv")
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                csvHandle = try FileHandle(forWritingTo: url)
                try csvHandle?.write(contentsOf: Data(CSVLog.header(id: session, target: target, start: start).utf8))
                try csvHandle?.synchronize()
                let diagnostic = dir.appendingPathComponent("diagnostics.txt")
                guard FileManager.default.createFile(atPath: diagnostic.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                handle = try FileHandle(forWritingTo: diagnostic); logURL = url
                lastCSVIndex = -1; lastCSVRow = ""; lastCSVOffset = 0
            } catch { notice = "无法创建日志：\(error.localizedDescription)"; return }
            write("session_start", message: "NetPulse 0.1 preview; macOS \(ProcessInfo.processInfo.operatingSystemVersionString); interval=1s; window=5s; timeout=1s; jitter=adjacent_rtt_delta_v1")
        } else { sequence += 1; write("resume") }
        guard handle != nil else { return }
        running = true; follow = true; notice = "正在探测 · 每 5 秒汇总，窗口等待回复后定稿"
        lastTick = ProcessInfo.processInfo.systemUptime
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func tick() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now-lastTick > 2.5 { sequence += 1; write("gap", message: "调度间隔 \(now-lastTick) 秒；未补造探测") }
        lastTick = now
        flushWindows()
        let id = sequence; sequence += 1
        let date = Date(); let elapsed = now-uptime; let token = generation
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-n", "-c", "1", "-W", "1000", "-t", "2", target]
        p.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin:/sbin"]
        p.standardOutput = pipe; p.standardError = pipe
        write("probe_start", message: "id=\(id); elapsed=\(elapsed)")
        guard running else { return }
        work[id] = p; pendingWindows[id] = Int(elapsed / 5)
        p.terminationHandler = { [weak self] process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(decoding: data, as: UTF8.self)
            let probe = parsePing(raw, id: id, date: date, elapsed: elapsed, exit: process.terminationStatus)
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.work.removeValue(forKey: id); self.pendingWindows.removeValue(forKey: id)
                self.consume(probe); self.write("probe", probe: probe); self.flushWindows()
            }
        }
        do { try p.run() }
        catch { work.removeValue(forKey: id); pendingWindows.removeValue(forKey: id); let probe = Probe(id: id, sentAt: date, elapsed: elapsed, status: "error", raw: error.localizedDescription); consume(probe); write("probe", probe: probe); flushWindows() }
        DispatchQueue.main.asyncAfter(deadline: .now()+4) { if p.isRunning { p.terminate() } }
        if follow { endDate = date }
    }
    func consume(_ probe: Probe) {
        sent += 1
        if probe.status == "reply" { received += 1 }
        if probe.status != "reply" && probe.status != "timeout" { errors += 1; notice = "探测错误：\(probe.status) · 请查看原始记录" }
        if let ip = probe.ip { resolved = ip }
        let index = Int(probe.elapsed / 5)
        if let i = samples.firstIndex(where: { $0.id == index }) { samples[i].probes.append(probe) }
        else { samples.append(WindowSample(id: index, date: start.addingTimeInterval(Double(index)*5), probes: [probe])); samples.sort { $0.id < $1.id } }
        // 保留约 24 小时图表；完整逐包记录持续保存在磁盘。
        if samples.count > 17280 { samples.removeFirst(samples.count-17280) }
    }
    func stop(writeEnd: Bool = true) {
        timer?.invalidate(); timer = nil; running = false
        if writeEnd { flushWindows(); write("pause", message: "停止发包；等待在途请求结束") ; notice = "探测已暂停 · 历史与日志保留" }
    }
    func finishForExit() async {
        stop()
        // Keep the event loop alive so in-flight ping callbacks can save their results.
        let deadline = ProcessInfo.processInfo.systemUptime + 4.5
        while !work.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        reset()
    }
    func reset() {
        stop(); generation = UUID()
        for p in work.values where p.isRunning { p.terminate() }; work = [:]; pendingWindows = [:]
        flushWindows(force: true)
        write("session_end"); try? handle?.close(); handle = nil; try? csvHandle?.close(); csvHandle = nil
        samples = []; sent = 0; received = 0; errors = 0; sequence = 0; imported = false
        logURL = nil; resolved = "—"; selectedDate = nil; follow = true; endDate = Date()
        notice = "新会话 · 输入目标开始探测"
    }
    func reveal() { if let logURL { NSWorkspace.shared.activateFileViewerSelecting([logURL]) } }
    func export() {
        guard let source = logURL else { return }
        flushWindows(force: true)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "NetPulse-\(session).netpulse"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try handle?.synchronize()
            let dir = !imported ? source.deletingLastPathComponent() : source
            // SavePanel 的覆盖确认不意味着可以递归删除目录；用新名称避免覆盖。
            guard !FileManager.default.fileExists(atPath: destination.path) else { notice = "请选择新的导出名称，避免覆盖已有材料"; return }
            if dir.hasDirectoryPath || (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try FileManager.default.copyItem(at: dir, to: destination)
            } else {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: dir, to: destination.appendingPathComponent(source.lastPathComponent))
            }
            notice = "已导出完整会话目录；包含目标、IP 和原始 Ping 输出，可压缩后发送"
        } catch { notice = "导出失败：\(error.localizedDescription)" }
    }

    func load() {
        guard !running else { notice = "请暂停探测后再导入"; return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = true; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }
    func load(url: URL) {
        do {
            let isDir = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            let csv = isDir ? url.appendingPathComponent("session.csv") : url
            if csv.pathExtension.lowercased() == "csv", FileManager.default.fileExists(atPath: csv.path) {
                let size = try csv.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 50_000_000 else { notice = "CSV 导入上限 50 MB"; return }
                let content = try String(contentsOf: csv, encoding: .utf8)
                let parsed = try CSVLog.read(content)
                reset(); imported = true; session = parsed.id; target = parsed.target; start = parsed.start
                samples = Array(parsed.samples.suffix(17280))
                sent = parsed.samples.reduce(0) { $0 + $1.sent }; received = parsed.samples.reduce(0) { $0 + $1.received }; errors = parsed.samples.reduce(0) { $0 + $1.errorCount }
                logURL = url; endDate = samples.last?.date.addingTimeInterval(5) ?? start; follow = false
                notice = "CSV 回放 · \(parsed.samples.count) 个窗口 · \(parsed.invalidRows) 行无效；逐包原始输出请查看 diagnostics.txt\(content.hasSuffix("\n") ? "" : "；文件尾部可能截断")"
                return
            }
            let files: [URL]
            if isDir {
                files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "jsonl" }
                    .sorted { a,b in if a.lastPathComponent == "session.jsonl" { return true }; if b.lastPathComponent == "session.jsonl" { return false }; return a.lastPathComponent < b.lastPathComponent }
            } else { files = [url] }
            let size = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            guard size <= 50_000_000 else { notice = "预览版支持导入总计不超过 50 MB 的日志"; return }
            var data = Data()
            for file in files { data.append(try Data(contentsOf: file)) }
            var records: [Record] = []; var bad = 0; var expected: String?
            for line in data.split(separator: 10) {
                guard let r = try? decoder.decode(Record.self, from: Data(line)), r.schema_version == 1,
                      expected == nil || r.session_id == expected else { bad += 1; continue }
                expected = r.session_id
                if let p = r.probe {
                    guard p.elapsed.isFinite, p.elapsed >= 0, p.elapsed < 31536000, p.id >= 0,
                          p.rtt == nil || (p.rtt!.isFinite && p.rtt! >= 0), ["reply","timeout","dns_error","error"].contains(p.status),
                          (p.status == "reply") == (p.rtt != nil) else { bad += 1; continue }
                }
                records.append(r)
            }
            guard let first = records.first, first.event_type == "session_start" else { notice = "无有效会话头；文件未导入"; return }
            reset(); imported = true; session = first.session_id; target = first.target ?? "未知"; start = first.timestamp
            var ids = Set<Int>()
            for r in records { if let p = r.probe { if ids.insert(p.id).inserted { consume(p) } else { bad += 1 } } }
            logURL = url; endDate = samples.last?.date.addingTimeInterval(5) ?? start; follow = false
            let started = records.filter { $0.event_type == "probe_start" }.count
            let unfinished = max(0, started - sent)
            notice = "离线回放 · \(sent) 条探测，\(unfinished) 条未完成，\(bad) 条无效/重复记录\(data.last == 10 ? "" : "；文件尾部可能截断")"
        } catch { notice = "导入失败：无有效会话头或文件损坏（\(error.localizedDescription)）" }
    }
    func jump(_ direction: Int) {
        follow = false
        let origin = selectedDate ?? endDate
        let list = samples.filter { ($0.loss ?? 0) > 0 }
        let sample = direction > 0 ? list.first { $0.date > origin } : list.last { $0.date < origin }
        if let sample { selectedDate = sample.date; endDate = sample.date.addingTimeInterval(span/2) }
        else { notice = "当前方向没有更多丢包窗口" }
    }
}
