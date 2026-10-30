import Foundation
import AppKit
import Network

struct SpeedHistoryItem: Identifiable {
    var id: URL { url }
    let url: URL
    let title: String
}
@MainActor final class SpeedStore: ObservableObject {
    @Published var provider = SpeedProvider.cloudflare
    @Published var budgetMB = 64
    @Published private(set) var running = false
    @Published private(set) var stopping = false
    @Published private(set) var phase = "准备就绪"
    @Published private(set) var notice = "点击开始后才会访问测速服务。测速会占用带宽，可能影响同时进行的业务和 Ping。"
    @Published private(set) var summary = SpeedSummary()
    @Published private(set) var samples: [SpeedSample] = []
    @Published private(set) var scheduledBytes = 0
    @Published private(set) var elapsed = 0.0
    @Published private(set) var logURL: URL?
    @Published private(set) var imported = false
    @Published private(set) var recordProvider = SpeedProvider.cloudflare
    @Published private(set) var webEngine: SpeedWebEngine?
    @Published private(set) var history: [SpeedHistoryItem] = []
    var canStart: (() -> Bool)?
    var onActivity: ((Bool) -> Void)?
    private var lastContext: LocalNetworkSnapshot?
    private var metadata: [String: String] = [:]
    private var token = UUID()
    private var timer: Timer?
    private var started = ProcessInfo.processInfo.systemUptime
    private var process: Process?
    private var monitor: NWPathMonitor?
    private var pathKey: String?
    private var contextTask: Task<Void, Never>?
    private let root: URL
    private let resource: URL
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NetPulse/Speed"), resource: URL? = nil) {
        self.root = root
        self.resource = resource ?? (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("speedtest")
        refreshHistory()
    }
    func begin() {
        guard !running && !stopping else { return }
        guard canStart?() != false else { notice = "周边 Wi-Fi 扫描正在运行，请等待扫描结束后测速。"; return }
        token = UUID(); let id = token
        summary = SpeedSummary(); samples = []; scheduledBytes = 0; elapsed = 0; imported = false; lastContext = nil
        recordProvider = provider; phase = "准备测量"; notice = "测速中，可随时停止；切换 TAB 不会中断。"
        metadata = ["Session": id.uuidString, "Provider": provider.rawValue, "Engine": provider.version, "App-Version": "0.1.0", "Started-At": SpeedCSV.timestamp(Date()), "Status": "running", "Endpoint": provider == .cloudflare ? "https://speed.cloudflare.com" : "Apple networkQuality default configuration", "Budget-Bytes": provider == .cloudflare ? String(SpeedPlan.make(megabytes: budgetMB).budget) : "uncapped", "Units": "throughput=bit/s; latency,jitter,duration=ms; responsiveness=RPM", "Packet-Loss": "not measured", "Aggregation": provider == .cloudflare ? "bandwidth percentile=0.90; idle latency percentile=0.50; custom sequential payload plan" : "networkQuality sequential; system aggregation"]
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            logURL = folder; try persist()
        } catch { logURL = nil; notice = "无法创建测速日志：\(error.localizedDescription)"; return }
        running = true; started = ProcessInfo.processInfo.systemUptime; onActivity?(true)
        contextTask = Task { [weak self] in
            let before = await Task.detached { LocalNetworkReader.read(path: LocalPathInfo(status: "测速本地快照（系统路径独立监控）")) }.value
            guard let self, running, token == id else { return }
            lastContext = before
            do { try LocalNetworkExport.snapshot(before, exit: nil, stale: false).write(to: folder.appendingPathComponent("network-context.txt"), atomically: true, encoding: .utf8) }
            catch { finish("failed", "网络上下文写入失败：\(error.localizedDescription)"); return }
            startMonitor(id)
            if recordProvider == .cloudflare { startCloudflare(id) } else { startSystem(id) }
            // Compare local route/Wi-Fi identity periodically, without active Wi-Fi scans.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, running, token == id else { return }
                let current = await Task.detached { LocalNetworkReader.read(path: LocalPathInfo(status: "测速本地快照（系统路径独立监控）")) }.value
                guard running, token == id else { return }
                lastContext = current
                if current.fingerprint != before.fingerprint { finish("network_changed", "本地网络配置发生变化，已停止；请新建测速。结果仅代表变化前的部分测量。"); return }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.token == id else { return }
                self.elapsed = ProcessInfo.processInfo.systemUptime - self.started
                if self.elapsed > (self.recordProvider == .cloudflare ? 180 : 45) { self.finish("timed_out", "测速达到时间上限，已停止并保留部分结果。") }
            }
        }
    }
    private func startCloudflare(_ id: UUID) {
        let plan = SpeedPlan.make(megabytes: budgetMB)
        let engine = SpeedWebEngine(resourceURL: resource); webEngine = engine
        engine.onFailure = { [weak self] error in guard let self, running, token == id else { return }; finish("failed", "Cloudflare 测速失败：\(error)") }
        engine.onMessage = { [weak self] value in self?.receive(value, id: id) }
        engine.start(["session": id.uuidString, "budget": plan.budget, "measurements": plan.measurements])
    }
    func receive(_ value: [String: Any], id: UUID) {
        guard running, token == id, value["session"] as? String == id.uuidString else { return }
        if let v = value["summary"] as? [String: Any] { summary = SpeedSummary.validated(v) }
        if let bytes = value["scheduledBytes"] as? Int, bytes >= 0 { scheduledBytes = bytes }
        if let points = value["points"] as? [[String: Any]] {
            var ids = Set<String>()
            samples = points.prefix(1000).compactMap { p in
                guard let key = p["id"] as? String, ids.insert(key).inserted, let kind = p["kind"] as? String, ["download", "upload"].contains(kind), let date = CSVLog.date(p["date"] as? String ?? ""), let bps = p["bps"] as? Double, bps.isFinite, bps >= 0 else { return nil }
                let duration = (p["duration"] as? Double).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                return SpeedSample(id: key, date: date, kind: kind, bps: bps, duration: duration)
            }
        }
        switch value["phase"] as? String {
        case "latency": phase = "测量空闲时延"
        case "download": phase = "测量下载与负载时延"
        case "upload": phase = "测量上传与负载时延"
        default: break
        }
        switch value["event"] as? String {
        case "finish":
            guard summary.values["download"] != nil, summary.values["upload"] != nil, summary.values["latency"] != nil else { finish("failed", "测速引擎已结束，但有效统计不足；已保留部分结果。"); return }
            let short = (samples.compactMap(\.duration).max() ?? 0) < 250
            finish("completed", "Cloudflare 测量完成。" + (short ? "请求持续时间偏短，吞吐结果可能未充分收敛。" : "") + "有限数据预算可能不足以跑满高速线路；可选择 256 MB 复测。")
        case "error": finish("failed", "Cloudflare 测速未完成：\(value["message"] as? String ?? "未知错误")")
        default: saveOrStop()
        }
    }
    private func startSystem(_ id: UUID) {
        phase = "系统测速中 · 等待最终结果"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality"); p.arguments = ["-s", "-M", "30", "-c"]
        p.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        let output = Pipe(); p.standardOutput = output; p.standardError = FileHandle.nullDevice; process = p
        do { try p.run() } catch { process = nil; finish("failed", "系统测速无法启动：\(error.localizedDescription)"); return }
        Task { [weak self] in
            let result: (Data, Bool) = await Task.detached {
                var data = Data(); var oversized = false
                while let chunk = try? output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                    if data.count + chunk.count <= 1_048_576 { data.append(chunk) } else { oversized = true; if p.isRunning { p.terminate() } }
                }
                p.waitUntilExit(); return (data, oversized || p.terminationStatus != 0)
            }.value
            guard let self, running, token == id else { return }
            process = nil
            do {
                guard !result.1 else { throw CocoaError(.fileReadCorruptFile) }
                summary = try SpeedSummary.system(result.0)
                finish("completed", "系统测速完成。RPM 为每分钟可完成的往返事务数，与 Ping RTT、Cloudflare 吞吐量口径不同。")
            } catch { finish("failed", "系统测速失败或返回了无法识别的结果；请检查网络后重试。") }
        }
    }
    private func startMonitor(_ id: UUID) {
        pathKey = nil
        let m = NWPathMonitor(); monitor = m
        m.pathUpdateHandler = { [weak self] path in
            let key = String(describing: path.status) + path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor in
                guard let self, self.running, self.token == id else { return }
                if let old = self.pathKey, old != key { self.finish("network_changed", "系统网络路径发生变化，已停止；请在新网络下重新测速。") } else { self.pathKey = key }
            }
        }
        m.start(queue: DispatchQueue(label: "NetPulse.speed.path"))
    }
    func stop() { if running { finish("stopped", "已停止，保留已完成的部分测量；再次开始会创建新日志。") } }
    func stopAndWait() async {
        stop()
        while stopping { try? await Task.sleep(nanoseconds: 50_000_000) }
    }
    private func finish(_ status: String, _ message: String) {
        guard running else { return }
        running = false; elapsed = ProcessInfo.processInfo.systemUptime - started
        timer?.invalidate(); timer = nil; contextTask?.cancel(); contextTask = nil; monitor?.cancel(); monitor = nil
        let engine = webEngine; let oldProcess = process
        engine?.stop(); webEngine = nil
        if let p = oldProcess, p.isRunning { p.terminate() }
        process = nil; stopping = true
        Task { [weak self] in
            // Hold the engine through JavaScript abort + page teardown, and wait
            // for the old process before permitting the next bandwidth test.
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let p = oldProcess, p.isRunning {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                await Task.detached { p.waitUntilExit() }.value
            }
            engine?.destroy()
            self?.stopping = false
        }
        onActivity?(false)
        metadata["Status"] = status; metadata["Ended-At"] = SpeedCSV.timestamp(Date()); metadata["Elapsed-Seconds"] = String(elapsed)
        phase = status == "completed" ? "测量完成" : status == "stopped" ? "已停止" : "未完成"
        notice = message; saveOrStop(); refreshHistory()
    }
    private func persist() throws {
        guard let logURL else { return }
        metadata["Scheduled-Payload-Bytes"] = String(scheduledBytes)
        if let lastContext { try LocalNetworkExport.snapshot(lastContext, exit: nil, stale: false).write(to: logURL.appendingPathComponent("network-last-observed.txt"), atomically: true, encoding: .utf8) }
        try SpeedCSV.samples(samples, session: metadata["Session"] ?? "").write(to: logURL.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)
        try SpeedCSV.summary(metadata, summary).write(to: logURL.appendingPathComponent("summary.csv"), atomically: true, encoding: .utf8)
    }
    private func saveOrStop() {
        do { try persist() } catch {
            if running { finish("failed", "测速日志写入失败，已停止测量：\(error.localizedDescription)") }
            else { notice = "日志写入失败：\(error.localizedDescription)" }
        }
    }
    @discardableResult func load(_ url: URL) -> Bool {
        guard !running else { return false }
        let folder = url.pathExtension.lowercased() == "csv" ? url.deletingLastPathComponent() : url
        do {
            let result = try Self.read(folder)
            metadata = result.metadata; summary = result.summary; samples = result.samples; imported = true
            recordProvider = SpeedProvider(rawValue: metadata["Provider"]!)!; logURL = folder
            scheduledBytes = Int(metadata["Scheduled-Payload-Bytes"] ?? "") ?? 0; elapsed = Double(metadata["Elapsed-Seconds"] ?? "") ?? 0
            phase = "离线回放 · \(metadata["Status"] ?? "")"; notice = "已导入本地测速记录，不会发起网络请求。缺失值表示未测得；running 表示日志未正常收尾。"
            return true
        } catch { notice = "导入失败：请选择同一会话的 summary.csv 与 samples.csv 所在目录。"; return false }
    }
    static func read(_ folder: URL) throws -> SpeedArchive {
        let a = folder.appendingPathComponent("summary.csv"), b = folder.appendingPathComponent("samples.csv")
        for url in [a, b] { let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0; guard size <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) } }
        return try SpeedCSV.decode(summary: String(contentsOf: a, encoding: .utf8), samples: String(contentsOf: b, encoding: .utf8))
    }
    func refreshHistory() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        history = folders.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }.prefix(40).compactMap { url in
            guard let archive = try? Self.read(url) else { return nil }
            return SpeedHistoryItem(url: url, title: "\(archive.metadata["Started-At"] ?? "") · \(archive.metadata["Provider"] ?? "") · \(archive.metadata["Status"] ?? "")")
        }.sorted { $0.title > $1.title }.prefix(20).map { $0 }
    }
    func reset() { guard !running && !stopping else { return }; summary = SpeedSummary(); samples = []; logURL = nil; imported = false; elapsed = 0; scheduledBytes = 0; phase = "准备就绪" }
    func reveal() { if let logURL { NSWorkspace.shared.activateFileViewerSelecting([logURL]) } }
    func export() {
        guard let logURL else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "NetPulse-Speed-\(metadata["Session"] ?? "record")"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            for name in ["summary.csv", "samples.csv", "network-context.txt", "network-last-observed.txt"] {
                let source = logURL.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: url.appendingPathComponent(name)) }
            }
            notice = "已导出完整测速日志目录。"
        }
        catch { notice = "导出失败：\(error.localizedDescription)" }
    }
}
