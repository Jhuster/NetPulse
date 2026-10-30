import Foundation
import AppKit
import Network
import CoreLocation

@MainActor final class LocalNetworkStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var snapshot = LocalNetworkSnapshot()
    @Published private(set) var history = WiFiHistory()
    @Published private(set) var observing = false
    @Published private(set) var observationEnabled = true
    @Published private(set) var reading = false
    @Published private(set) var exitInfo: PublicExitInfo?
    @Published private(set) var exitStale = false
    @Published private(set) var queryingExit = false
    @Published private(set) var exitMessage = "点击查询 IP.SB；服务商会看到该请求的出口 IP，不上传局域网地址和 Wi-Fi 标识。"
    @Published private(set) var permission: CLAuthorizationStatus = .notDetermined
    @Published var notice = "本地信息每 2 秒刷新，离开本页后停止采样；出口信息按需查询。"
    @Published private(set) var lastChange: Date?
    @Published private(set) var nearbyScan: WiFiScanResult?
    @Published private(set) var scanStale = false
    @Published private(set) var scanBusy = false
    @Published private(set) var scanWaiting = false
    @Published private(set) var scanMessage = "按需扫描周边 Wi-Fi，不会自动定时扫描或切换网络。"
    @Published private(set) var connections = WiFiConnectionHistory()
    var scanTimeoutSeconds: Double = 20
    private var scanJob = UUID()
    private var scanGeneration = UUID()
    private var scanDeadline: Task<Void, Never>?
    private let scanner: @Sendable (String) throws -> WiFiScanResult
    private let scanPermission: (() -> Bool)?
    private var timer: Timer?
    private var monitor: NWPathMonitor?
    private var path = LocalPathInfo()
    private var monitorToken = UUID()
    private var readToken = UUID()
    private var exitToken = UUID()
    private var fingerprint = ""
    private var pendingRead = false
    private let location = CLLocationManager()
    private var exitTask: Task<Void, Never>?
    private let reader: @Sendable (LocalPathInfo) -> LocalNetworkSnapshot
    private let fetchExit: @Sendable () async throws -> PublicExitInfo
    init(reader: @escaping @Sendable (LocalPathInfo) -> LocalNetworkSnapshot = { LocalNetworkReader.read(path: $0) },
         fetchExit: @escaping @Sendable () async throws -> PublicExitInfo = { try await LocalNetworkStore.fetchPublicExit() },
         scanner: @escaping @Sendable (String) throws -> WiFiScanResult = { try WiFiScanner.scan(interface: $0) },
         scanPermission: (() -> Bool)? = nil) {
        self.reader = reader; self.fetchExit = fetchExit
        self.scanner = scanner; self.scanPermission = scanPermission
        super.init()
        location.delegate = self; permission = location.authorizationStatus
    }
    func start() {
        guard !observing else { return }
        observing = true
        let generation = UUID(); monitorToken = generation
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            var info = LocalPathInfo()
            info.status = path.status == .satisfied ? "系统路径可用" : path.status == .requiresConnection ? "需要建立连接" : "系统路径不可用"
            info.available = path.status == .satisfied
            let types: [(NWInterface.InterfaceType, String)] = [(.wifi, "Wi-Fi"), (.wiredEthernet, "有线 / 以太网"), (.cellular, "移动网络"), (.other, "其他 / 虚拟路径")]
            info.kinds = types.filter { path.usesInterfaceType($0.0) }.map(\.1)
            info.interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name).sorted()
            info.expensive = path.isExpensive; info.constrained = path.isConstrained
            info.ipv4 = path.supportsIPv4; info.ipv6 = path.supportsIPv6
            Task { @MainActor [weak self] in
                guard let self, self.observing, self.monitorToken == generation else { return }
                self.path = info; self.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetPulse.local-path"))
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }
    func enter() { observationEnabled ? start() : refresh() }
    func toggleObservation() {
        observationEnabled.toggle()
        if observationEnabled { start() } else { stop() }
    }
    func stop() {
        history.breakContinuity()
        connections.breakContinuity()
        observing = false; timer?.invalidate(); timer = nil
        monitorToken = UUID(); monitor?.cancel(); monitor = nil
        readToken = UUID(); pendingRead = false; reading = false
    }
    func refresh() {
        // Avoid overlapping CoreWLAN reads with an off-channel scan. The next
        // snapshot marks the observation gap rather than inventing a disconnect.
        if scanBusy { pendingRead = true; return }
        if reading { pendingRead = true; return }
        reading = true
        let generation = UUID(); readToken = generation
        let path = path; let reader = reader
        Task {
            let value = await Task.detached(priority: .utility) { reader(path) }.value
            guard readToken == generation else { return }
            reading = false
            if path == self.path { accept(value, record: observing) }
            else { pendingRead = true }
            if pendingRead { pendingRead = false; refresh() }
        }
    }
    // Shared by live updates and deterministic tests; no network operations here.
    func accept(_ value: LocalNetworkSnapshot, record: Bool = true) {
        if !fingerprint.isEmpty && fingerprint != value.fingerprint {
            lastChange = value.date
            invalidateNearbyScan("本机配置已变化；上次扫描只是旧快照，请重新扫描。")
            if exitInfo != nil || queryingExit {
                exitStale = true; exitToken = UUID(); exitTask?.cancel(); queryingExit = false
                exitMessage = "本机网络配置已变化，旧出口信息已过期；请重新查询。"
            }
        }
        fingerprint = value.fingerprint; snapshot = value
        if record { history.append(value); connections.append(value) }
    }
    func requestWiFiPermission() {
        if permission == .notDetermined { location.requestWhenInUseAuthorization() }
        else if permission == .denied || permission == .restricted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
        } else { refresh() }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.permission = status
            if status != .authorizedAlways && self?.canScanNearby != true { self?.invalidateNearbyScan("权限状态已变化，上次扫描不代表当前结果。") }
            if self?.observing == true { self?.refresh() }
        }
    }
    var permissionGranted: Bool { permission == .authorizedAlways }
    var canScanNearby: Bool { scanPermission?() ?? permissionGranted }
    func scanNearby() {
        guard !scanBusy else { return }
        guard !reading else { scanMessage = "正在刷新本机信息，请稍候再扫描。"; return }
        guard canScanNearby else { scanMessage = "请先授权定位以读取周边 Wi-Fi 标识；不会读取 GPS 位置。"; return }
        guard let wifi = snapshot.wifi, !wifi.interface.isEmpty else { scanMessage = WiFiScanError.unavailable.localizedDescription; return }
        guard wifi.power else { scanMessage = WiFiScanError.poweredOff.localizedDescription; return }
        let job = UUID(); scanJob = job; scanGeneration = job
        scanBusy = true; scanWaiting = true; scanStale = nearbyScan != nil
        scanMessage = "正在扫描 \(wifi.interface)… 扫描可能短时影响无线时延。"
        let scanner = scanner; let name = wifi.interface; let scanPath = path
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try scanner(name) } }.value
            guard let self, scanJob == job else { return }
            scanBusy = false; scanDeadline?.cancel()
            defer { if pendingRead { pendingRead = false; refresh() } }
            guard scanGeneration == job else { scanMessage += " 系统扫描已结束。"; return }
            guard path == scanPath else { scanWaiting = false; scanMessage = "扫描期间系统路径已变化，结果未用于当前视图，请重新扫描。"; return }
            scanWaiting = false
            switch result {
            case .success(let result):
                nearbyScan = result; scanStale = false
                scanMessage = "扫描完成 · \(result.networks.count) 条结果\(result.total > result.networks.count ? "（仅保留前 512 条）" : "")；这是扫描时刻快照，不是实时拥塞测量。"
            case .failure(let error): scanMessage = "扫描失败：\(error.localizedDescription)。可刷新本机信息后重试；旧快照保留。"
            }
        }
        let timeout = scanTimeoutSeconds
        scanDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000)) } catch { return }
            guard let self, scanJob == job, scanBusy, scanGeneration == job else { return }
            stopWaitingForScan()
            scanMessage = "等待扫描超时；系统调用尚未结束，期间不会启动重复扫描。迟到结果不用于当前视图。"
        }
    }
    func stopWaitingForScan() {
        scanGeneration = UUID(); scanWaiting = false; scanDeadline?.cancel()
        scanMessage = "已结束等待；系统扫描尚在后台结束，迟到结果不会显示。"
    }
    private func invalidateNearbyScan(_ message: String) {
        guard nearbyScan != nil || scanBusy else { return }
        scanStale = nearbyScan != nil; scanGeneration = UUID(); scanWaiting = false; scanDeadline?.cancel(); scanMessage = message
    }
    func queryExit() {
        guard !queryingExit else { return }
        exitTask?.cancel(); let generation = UUID(); exitToken = generation
        queryingExit = true; exitStale = exitInfo != nil; exitMessage = "正在查询 IP.SB…"
        let query = fetchExit
        exitTask = Task {
            do {
                let info = try await query()
                guard !Task.isCancelled, exitToken == generation else { return }
                exitInfo = info; exitStale = false; exitMessage = "来源 IP.SB · 该 HTTPS 请求的出口网络归属"; queryingExit = false
            } catch {
                guard exitToken == generation else { return }
                queryingExit = false; exitStale = exitInfo != nil
                exitMessage = "查询失败：\(error.localizedDescription)；可稍后重试。"
            }
        }
    }
    nonisolated static func fetchPublicExit() async throws -> PublicExitInfo {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://api.ip.sb/geoip")!)
        request.setValue("NetPulse/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https", http.url?.host == "api.ip.sb" else { throw LocalNetworkError.invalidResponse }
        guard http.statusCode == 200 else { throw LocalNetworkError.http(http.statusCode) }
        return try PublicExitInfo.decode(data)
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "NetPulse-local-\(UUID().uuidString.prefix(8)).netpulse"
        panel.message = "包含本机 IP、可读取的 Wi-Fi 名称/BSSID、出口、信号、连接记录及已扫描的周边 Wi-Fi 标识。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeExport(to: url)
            notice = "已导出本机网络快照和信号 CSV · \(url.path)"
        } catch { notice = "导出失败：\(error.localizedDescription)" }
    }
    func writeExport(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try Data(LocalNetworkExport.snapshot(snapshot, exit: exitInfo, stale: exitStale).utf8).write(to: url.appendingPathComponent("network.txt"), options: .atomic)
            try Data(LocalNetworkExport.signalCSV(history.samples).utf8).write(to: url.appendingPathComponent("wifi.csv"), options: .atomic)
            if let nearbyScan { try Data(WiFiDiagnosticsCSV.scan(nearbyScan, stale: scanStale).utf8).write(to: url.appendingPathComponent("wifi-scan.csv"), options: .atomic) }
            try Data(WiFiDiagnosticsCSV.events(connections.events).utf8).write(to: url.appendingPathComponent("wifi-events.csv"), options: .atomic)
        } catch {
            // This directory was created by this operation; do not leave a partial export.
            try? FileManager.default.removeItem(at: url); throw error
        }
    }
}
