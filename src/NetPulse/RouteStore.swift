import Foundation
import AppKit
import Darwin
import UniformTypeIdentifiers

@MainActor final class RouteStore: ObservableObject {
    @Published var mode = RouteMode.quick
    let mtr = MTRStore()
    @Published var running = false
    @Published var imported = false
    @Published var target = "1.1.1.1"
    @Published var targetIP = ""
    @Published var gateway = ""
    @Published var networkInterface = ""
    @Published var hops: [RouteHop] = []
    @Published var selectedHop: Int?
    @Published var message = "快速查看一次路径；点击节点查看该跳样本"
    @Published var state = "idle"
    @Published var logURL: URL?
    @Published var geo: [String:GeoLocation] = [:]
    @Published var geoSource = "未安装归属数据库"
    @Published var geoDatabase: GeoDatabase?
    @Published var geoLoading = false
    @Published var geoDownloading = false
    @Published var geoDownloadProgress: Double?
    private var geoDownloadTask: Task<Void, Never>?
    @Published var geoMessage = "安装一次数据库，扫描时自动离线查询；不会上传路径 IP。"
    private let geoDirectory: URL
    private var geoRevision = UUID()
    private var geoTask: Task<Void, Never>?
    var logRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NetPulse")
    var process: Process?
    var gatewayProcess: Process?
    var token = UUID()
    var started = Date()
    var raw = ""
    var pending = ""
    var diagnostics: FileHandle?
    var exitRequested: String?
    var hopLimit = 30
    var timeBudget: Double = 60
    var pinnedGeo: [String:GeoLocation] = [:]
    var pinnedGeoSource = "未导入归属表"
    private let executableURL: URL
    private let overrideArguments: [String]?
    init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/traceroute"), arguments: [String]? = nil, geoDirectory: URL = GeoDatabaseInstaller.defaultDirectory) {
        self.executableURL = executableURL
        self.overrideArguments = arguments
        self.geoDirectory = geoDirectory
        mtr.onChange = { [weak self] in self?.syncMTR() }
        mtr.location = { [weak self] ip in self?.geo[ip] }
        mtr.onAddress = { [weak self] ip in
            guard let self else { return }
            self.targetIP = ip; self.findGateway(ip, generation: self.token)
        }
        let file = GeoDatabaseInstaller.databaseURL(in: geoDirectory)
        if FileManager.default.fileExists(atPath: file.path) {
            geoLoading = true
            Task { await restoreGeoDatabase(file) }
        }
    }
    private func syncMTR() {
        guard mode == .continuous else { return }
        running = mtr.running || mtr.stopping; imported = mtr.imported; targetIP = mtr.targetIP
        logURL = mtr.logURL; state = mtr.state; message = mtr.message; raw = mtr.raw
        if !mtr.target.isEmpty { target = mtr.target }
        let grouped = Dictionary(grouping: mtr.samples.filter { $0.kind == "hop" && $0.segment == mtr.segment }, by: \.ttl)
        hops = grouped.keys.sorted().map { ttl in
            RouteHop(id: ttl, probes: Array(grouped[ttl]!.suffix(100)).enumerated().map { index, sample in
                RouteProbe(id: index, address: sample.address.isEmpty ? nil : sample.address, rtt: sample.rtt, annotation: sample.annotation)
            }, raw: "持续观察样本")
        }
        // Log geography snapshots only for future samples; offline archives retain their original values.
        if !imported { resolveGeography() }
    }
    var selected: RouteHop? { hops.first { $0.id == selectedHop } ?? hops.last }
    var hasSession: Bool { logURL != nil }
    var observedTarget: Bool { !targetIP.isEmpty && hops.contains { h in h.probes.contains { $0.address == targetIP && $0.rtt != nil && $0.annotation.isEmpty } } }
    var statusTitle: String {
        if mode == .continuous {
            if mtr.stopping { return "正在回收探测进程" }
            switch state {
            case "running": return imported ? "未完成的持续观察记录" : "持续观察中"
            case "paused": return "已暂停"
            case "failed": return "持续观察失败"
            default: return "准备就绪"
            }
        }
        switch state {
        case "running": return imported ? "未完成扫描记录" : "正在扫描"
        case "completed": return "观察到目标回复"
        case "not_reached": return "未确认目标回复"
        case "cancelled": return "已停止 · 部分结果"
        case "timed_out": return "已到时间预算"
        case "failed": return "扫描失败"
        default: return "准备就绪"
        }
    }
    var metadata: [String:String] {
        ["App-Version":"0.1.0", "Target":target, "Target-IP":targetIP, "Started-At":CSVLog.timestamp(started), "Protocol":"ICMP", "Status":state, "Gateway":gateway, "Interface":networkInterface, "Max-TTL":String(hopLimit), "Samples-Per-TTL":"3", "Timeout-Seconds":"1", "Geo-Source":geoSource]
    }
    func geoText(_ ip: String) -> String {
        if nonPublicAddress(ip) { return "内网/共享地址 · 地域不适用" }
        if !geographicAddress(ip), geo[ip] == nil { return "保留地址 · 地域不适用" }
        guard let place = geo[ip] else { return "国家未知 · 省份未知" }
        return "\(place.country.isEmpty ? "国家未知" : place.country) · \(place.province.isEmpty ? "省份未知" : place.province)"
    }
    func save() {
        guard let logURL, !imported else { return }
        if mode == .continuous {
            mtr.updateContext(["Gateway": gateway, "Interface": networkInterface, "Geo-Source": geoSource]); return
        }
        do { try Data(RouteCSV.encode(metadata, hops: hops, geo: geo).utf8).write(to: logURL, options: .atomic) }
        catch { halt("failed"); running = false; state = "failed"; message = "路径日志写入失败：\(error.localizedDescription)" }
    }
    func begin(_ address: String) {
        if mode == .continuous {
            guard !running, !imported else { return }
            mtr.logRoot = logRoot; mtr.hopLimit = min(30, hopLimit)
            mtr.begin(address); syncMTR(); return
        }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !running else { return }
        guard !address.isEmpty, address.count <= 253, address.first != "-", address.range(of: "^[A-Za-z0-9][A-Za-z0-9.\\-]*$", options: .regularExpression) != nil else { message = "请输入域名或 IPv4 地址，不包含协议、端口或路径"; return }
        reset(); target = address; started = Date(); geo = pinnedGeo; imported = false; exitRequested = nil
        do {
            let dir = logRoot.appendingPathComponent("route-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            logURL = dir.appendingPathComponent("route.csv")
            let url = dir.appendingPathComponent("route-diagnostics.txt")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            diagnostics = try FileHandle(forWritingTo: url)
            try diagnostics?.write(contentsOf: Data("NetPulse route scan · \(address) · ICMP · \(CSVLog.timestamp(started))\n".utf8))
        } catch { message = "无法创建路径日志：\(error.localizedDescription)"; state = "failed"; return }
        let p = Process(); let pipe = Pipe(); let generation = token
        p.executableURL = executableURL
        p.arguments = overrideArguments ?? ["-I", "-n", "-m", String(hopLimit), "-q", "3", "-w", "1", address]
        p.environment = ["LC_ALL":"C", "LANG":"C", "PATH":"/usr/bin:/bin:/sbin:/usr/sbin"]
        p.standardOutput = pipe; p.standardError = pipe; process = p
        state = "running"; running = true; message = "扫描中 · ICMP · 最多 \(hopLimit) 跳 · 总预算 \(Int(timeBudget)) 秒"
        save()
        guard running else { return }
        do { try p.run() }
        catch { running = false; state = "failed"; process = nil; message = "无法启动系统 traceroute：\(error.localizedDescription)"; save(); try? diagnostics?.close(); diagnostics = nil; return }
        // A single serial reader preserves output order, including the final unterminated line.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                DispatchQueue.main.async { [weak self] in self?.receive(data, generation: generation) }
            }
            p.waitUntilExit()
            DispatchQueue.main.async { [weak self] in self?.finish(exit: p.terminationStatus, generation: generation) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+timeBudget) { [weak self] in
            guard let self, self.token == generation, self.running else { return }
            self.halt("timed_out")
        }
    }
    func receive(_ data: Data, generation: UUID) {
        guard token == generation else { return }
        guard raw.utf8.count + data.count <= 1_000_000 else { halt("failed"); message = "系统输出超过 1 MB 上限，已停止"; return }
        let text = String(decoding: data, as: UTF8.self); raw += text
        do { try diagnostics?.write(contentsOf: data); try diagnostics?.synchronize() }
        catch { halt("failed"); message = "诊断日志保存失败：\(error.localizedDescription)"; return }
        pending += text
        while let index = pending.firstIndex(of: "\n") {
            let line = String(pending[..<index]); pending.removeSubrange(...index); consume(line)
        }
    }
    func consume(_ line: String) {
        if let ip = routeTargetIP(line), targetIP != ip { targetIP = ip; findGateway(ip, generation: token) }
        if let hop = parseRouteHop(line) {
            if let index = hops.firstIndex(where: { $0.id == hop.id }) { hops[index] = hop }
            else { hops.append(hop); hops.sort { $0.id < $1.id } }
            if selectedHop == nil || hop.addresses.contains(targetIP) { selectedHop = hop.id }
            resolveGeography()
            if exitRequested == nil { message = "已观察到第 \(hop.id) 跳 · \(hops.filter { $0.received > 0 }.count) 个 TTL 收到回复" }
        }
        save()
    }
    func finish(exit: Int32, generation: UUID) {
        guard token == generation else { return }
        if !pending.isEmpty { let last = pending; pending = ""; consume(last) }
        running = false; process = nil
        if let requested = exitRequested { state = requested }
        else if exit != 0 { state = "failed"; message = "系统 traceroute 退出码 \(exit)。请查看原始输出（可能为解析、权限或网络错误）" }
        else { state = observedTarget ? "completed" : "not_reached" }
        if state != "failed" { message = statusTitle + " · 中间未回复不等于转发丢包" }
        save(); try? diagnostics?.close(); diagnostics = nil
    }
    func halt(_ reason: String = "cancelled") {
        if mode == .continuous { mtr.pause(); syncMTR(); return }
        guard running else { return }
        exitRequested = reason; state = reason
        message = reason == "timed_out" ? "已到时间预算，正在保存部分结果" : "正在停止并保存已收到的结果"
        let p = process
        if p?.isRunning == true { p?.terminate() }
        let generation = token
        DispatchQueue.main.asyncAfter(deadline: .now()+2) { [weak self] in
            guard self?.token == generation, let p, p.isRunning else { return }
            Darwin.kill(p.processIdentifier, SIGKILL)
        }
    }
    func stopAndWait() async {
        if mode == .continuous { await mtr.stopAndWait(); syncMTR(); return }
        halt()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while running && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if running { reset() }
    }
    func reset() {
        mtr.reset()
        geoTask?.cancel(); geoRevision = UUID()
        token = UUID()
        if let p = process, p.isRunning { p.terminate(); Darwin.kill(p.processIdentifier, SIGKILL) }
        if let p = gatewayProcess, p.isRunning { p.terminate() }
        try? diagnostics?.close(); diagnostics = nil; process = nil; gatewayProcess = nil
        running = false; imported = false; hops = []; selectedHop = nil; targetIP = ""; gateway = ""; networkInterface = ""; raw = ""; pending = ""; logURL = nil; state = "idle"; exitRequested = nil
        geo = pinnedGeo; updateGeoSource(); message = "快速查看一次路径；点击节点查看该跳样本"
    }
    func findGateway(_ ip: String, generation: UUID) {
        let p = Process(); let pipe = Pipe(); gatewayProcess = p
        p.executableURL = URL(fileURLWithPath: "/sbin/route"); p.arguments = ["-n", "get", ip]; p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { networkInterface = "路由查询失败"; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == generation, !self.imported, self.gatewayProcess === p else { return }
                self.gateway = capture("(?m)^\\s*gateway:\\s*([0-9.]+)", text).flatMap { validIPv4($0) ? $0 : nil } ?? ""
                self.networkInterface = capture("(?m)^\\s*interface:\\s*(\\S+)", text) ?? "未识别"
                self.gatewayProcess = nil; self.save()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+3) { if p.isRunning { p.terminate() } }
    }
    func importGeo() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadGeo(url)
    }
    @discardableResult func loadGeo(_ url: URL) -> Bool {
        guard !imported else { geoMessage = "历史回放保留日志中的归属信息；请新建测试后再导入归属表"; return false }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 10_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\u{feff}", with: "")
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard lines.first == "ip,country,province" else { geoMessage = "归属表首行应为 ip,country,province"; return false }
            var values: [String:GeoLocation] = [:]; var bad = 0
            for line in lines.dropFirst() {
                guard let c = try? RouteCSV.fields(line), c.count == 3, validIPv4(c[0]), !nonPublicAddress(c[0]), values[c[0]] == nil else { bad += 1; continue }
                values[c[0]] = GeoLocation(country: c[1], province: c[2], source: url.lastPathComponent)
            }
            guard !values.isEmpty else { geoMessage = "归属表没有有效的公网 IP 记录"; return false }
            pinnedGeo = values; geo = values; pinnedGeoSource = url.lastPathComponent
            updateGeoSource(); resolveGeography()
            geoMessage = "已导入 \(values.count) 个精确 IP 归属，\(bad) 行无效；优先于数据库匹配"; save(); return true
        } catch { geoMessage = "归属表读取失败：\(error.localizedDescription)"; return false }
    }
    private func updateGeoSource() {
        geoSource = ([geoDatabase?.source, pinnedGeo.isEmpty ? nil : "覆盖表：\(pinnedGeoSource)"].compactMap { $0 }).joined(separator: "；")
        if geoSource.isEmpty { geoSource = "未安装归属数据库" }
    }
    func importGeoDatabase() {
        guard !geoLoading else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.title = "选择 IP 地理归属数据库"
        panel.message = "支持 DB-IP City Lite / GeoLite City、Country 的 .mmdb 或 .mmdb.gz 文件。安装后离线查询。"
        panel.allowedContentTypes = [UTType(filenameExtension: "mmdb"), UTType(filenameExtension: "gz")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await installGeoDatabase(url) }
    }
    func installGeoDatabase(_ url: URL) async {
        guard !geoLoading, !imported else { return }
        geoLoading = true; geoMessage = "正在校验并安装数据库…"
        let directory = geoDirectory
        let result = await Task.detached(priority: .utility) { Result { try GeoDatabaseInstaller.install(from: url, in: directory) } }.value
        acceptGeoDatabase(result)
    }
    func downloadGeoDatabase() {
        guard !geoLoading, !imported else { return }
        geoLoading = true; geoDownloading = true; geoDownloadProgress = nil
        geoMessage = "正在获取官方最新版本…"
        geoDownloadTask = Task { [self] in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NetPulse-download-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder); geoDownloadTask = nil; geoDownloading = false; geoDownloadProgress = nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = try await GeoDownload.latestArchiveURL()
                try Task.checkCancellation()
                let operation = GeoDownload(destination: folder.appendingPathComponent("database.mmdb.gz")) { [weak self] received, expected in
                    Task { @MainActor [weak self] in
                        guard let self, self.geoDownloading else { return }
                        self.geoDownloadProgress = expected > 0 ? min(1, Double(received) / Double(expected)) : nil
                        let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                        let total = expected > 0 ? " / " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : ""
                        self.geoMessage = "正在下载 DB-IP City Lite · \(done)\(total)"
                    }
                }
                let file = try await operation.download(url)
                try Task.checkCancellation()
                geoDownloading = false; geoDownloadProgress = nil; geoMessage = "下载完成，正在解压、校验并安装…"
                let directory = geoDirectory
                let result = await Task.detached(priority: .utility) { Result { try GeoDatabaseInstaller.install(from: file, in: directory) } }.value
                acceptGeoDatabase(result)
            } catch {
                geoLoading = false
                geoMessage = Task.isCancelled ? "下载已取消，原有数据库保留" : "下载失败：\(error.localizedDescription)。可重试或导入文件；原有数据库保留。"
            }
        }
    }
    func cancelGeoDownload() { geoDownloadTask?.cancel() }
    private func restoreGeoDatabase(_ url: URL) async {
        let result = await Task.detached(priority: .utility) { Result { try GeoDatabase(url: url) } }.value
        acceptGeoDatabase(result)
    }
    private func acceptGeoDatabase(_ result: Result<GeoDatabase, Error>) {
        geoLoading = false
        switch result {
        case .success(let database):
            geoDatabase = database
            geoMessage = "数据库已就绪 · 本地查询 · 可导入新版文件更新"
            if !imported { geo = pinnedGeo; updateGeoSource(); resolveGeography(); save() }
        case .failure(let error): geoMessage = "数据库加载失败：\(error.localizedDescription)；原有数据库保持可用"
        }
    }
    func resolveGeography() {
        guard !imported, let database = geoDatabase else { return }
        geoTask?.cancel()
        let revision = UUID(); geoRevision = revision
        let generation = token
        let addresses = Set(hops.flatMap(\.addresses)).filter { geo[$0] == nil && geographicAddress($0) }
        guard !addresses.isEmpty else { return }
        geoTask = Task {
            let result = await Task.detached(priority: .utility) { () -> ([String:GeoLocation], Bool) in
                var values: [String:GeoLocation] = [:]; var failed = false
                for ip in addresses {
                    do { if let value = try database.lookup(ip) { values[ip] = value } }
                    catch { failed = true }
                }
                return (values, failed)
            }.value
            guard !Task.isCancelled, token == generation, geoRevision == revision, !imported else { return }
            geo.merge(result.0) { current, _ in current }
            if result.1 { geoMessage = "部分记录读取失败，未匹配节点保持未知；可重新安装数据库" }
            save()
        }
    }
    @discardableResult func load(_ url: URL) -> Bool {
        guard !running else { message = "请停止扫描后再导入"; return false }
        do {
            let isDir = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let file = isDir ? url.appendingPathComponent(FileManager.default.fileExists(atPath: url.appendingPathComponent("mtr.csv").path) ? "mtr.csv" : "route.csv") : url
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 50_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.hasPrefix("# MTR-Log-Version:") || text.contains("# Type: NetPulse-MTR\n") || text.contains("# Type: NetPulse-MTR\r\n") {
                let archive = try MTRCSV.decode(text)
                reset(); mode = .continuous
                gateway = archive.metadata["Gateway"] ?? ""; networkInterface = archive.metadata["Interface"] ?? ""
                geoSource = archive.metadata["Geo-Source"] ?? "日志快照"
                mtr.load(archive, from: file); syncMTR(); return true
            }
            let archive = try RouteCSV.decode(text)
            reset(); mode = .quick; imported = true; target = archive.metadata["Target"]!; targetIP = archive.metadata["Target-IP"] ?? ""; started = CSVLog.date(archive.metadata["Started-At"]!)!; gateway = archive.metadata["Gateway"] ?? ""; networkInterface = archive.metadata["Interface"] ?? ""; geoSource = archive.metadata["Geo-Source"] ?? "日志记录"
            hops = archive.hops; geo = archive.geo; selectedHop = hops.last?.id; state = archive.metadata["Status"] ?? "not_reached"; logURL = file
            let missingTarget = state == "completed" && !observedTarget
            if missingTarget { state = "not_reached" }
            message = "离线回放 · \(hops.count) 跳，\(archive.invalid) 行无效\(text.hasSuffix("\n") ? "" : "；文件尾部可能截断")\(missingTarget ? "；未恢复到目标回复，不能确认完成" : "")"
            if let note = archive.metadata["Data-Note"], !note.isEmpty { message += " · " + String(note.prefix(200)) }
            return true
        } catch { message = "路径日志导入失败：\(error.localizedDescription)"; return false }
    }
    func importLog() -> Bool {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }; return load(url)
    }
    func reveal() { if let logURL { NSWorkspace.shared.activateFileViewerSelecting([logURL]) } }
    func export() {
        guard let logURL else { return }; save()
        let panel = NSSavePanel(); panel.nameFieldStringValue = "NetPulse-route-\(UUID().uuidString.prefix(8)).netpulse"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: destination.path) else { message = "请选择新的导出名称"; return }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let name = mode == .continuous ? "mtr.csv" : "route.csv"
            let diagnosticName = mode == .continuous ? "mtr-diagnostics.txt" : "route-diagnostics.txt"
            try FileManager.default.copyItem(at: logURL, to: destination.appendingPathComponent(name))
            let raw = logURL.deletingLastPathComponent().appendingPathComponent(diagnosticName)
            if FileManager.default.fileExists(atPath: raw.path) { try FileManager.default.copyItem(at: raw, to: destination.appendingPathComponent(diagnosticName)) }
            message = "已导出路径会话；包含目标、路径 IP 和可用的诊断记录"
        } catch { message = "路径导出失败：\(error.localizedDescription)" }
    }
}
