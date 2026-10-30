// Screenshot harness only. All values are synthetic; never included in release builds.
import SwiftUI

@MainActor enum ReadmeFixtures {
    nonisolated static let clock = Date()
    static let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "NetPulsePreviewRoot") as! String)
    static let folder = root.appendingPathComponent(".build/readme-fixtures")
    nonisolated static func snapshot(_ offset: Double = 0) -> LocalNetworkSnapshot {
        var s = LocalNetworkSnapshot(); s.date = clock.addingTimeInterval(offset)
        s.path = LocalPathInfo(status: "演示路径可用", available: true, kinds: ["Wi-Fi"], interfaces: ["en0"], ipv4: true, ipv6: true)
        s.primaryInterface = "en0"; s.gateway4 = "192.168.50.1"; s.dns = ["192.0.2.53"]
        s.interfaces = [LocalInterfaceInfo(id: "en0", name: "Wi-Fi", kind: "Wi-Fi", addresses: ["192.168.50.23"], up: true, virtual: false)]
        let signal = -58 + Int(9 * sin(offset / 22)) + Int(3 * sin(offset / 5))
        s.wifi = WiFiInfo(interface: "en0", power: true, connected: true, ssid: "NetPulse Demo", bssid: "02:00:00:00:00:01", rssi: signal, noise: -96 + Int(3 * sin(offset / 13)), txRate: 540 + 80 * sin(offset / 25), channel: 36, band: "5 GHz", width: "80 MHz", phy: "802.11ax / Wi-Fi 6", security: "WPA2 Personal")
        return s
    }
    static func makeLocal() -> LocalNetworkStore {
        LocalNetworkStore(reader: { _ in snapshot() }, fetchExit: {
            PublicExitInfo(ip: "198.51.100.42", isp: "演示运营商", organization: "Example Network", asn: "AS64500", country: "演示地区", date: clock)
        }, scanner: { _ in WiFiDiagnosticsFixtures.scan() }, scanPermission: { true })
    }
    static func prepare(_ w: Workspaces) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let start = clock.addingTimeInterval(-300)
            var ping = CSVLog.header(id: "readme-synthetic-ping", target: "demo.example", start: start)
            for i in 0..<60 {
                let avg = 22 + 12 * abs(sin(Double(i) / 4)) + ((14...19).contains(i) ? 90 : 0)
                let received = [15, 16, 26].contains(i) ? 3 : (i == 17 ? 0 : 5)
                let row = WindowSample(id: i, date: start.addingTimeInterval(Double(i) * 5), probes: [], summary: WindowSummary(sent: 5, received: received, errors: 0, loss: Double(5 - received) * 20, avg: received > 0 ? avg : nil, jitter: received > 0 ? 2 + 9 * abs(sin(Double(i) / 3)) + ((14...20).contains(i) ? 18 : 0) : nil, minimum: received > 0 ? max(1, avg - 8) : nil, maximum: received > 0 ? avg + 15 : nil))
                ping += CSVLog.row(row)
            }
            let pingURL = folder.appendingPathComponent("ping-demo.csv"); try ping.write(to: pingURL, atomically: true, encoding: .utf8)
            w.ping.load(url: pingURL); w.ping.notice = "演示数据 · 展示丢包、时延升高及恢复，非真实测量"; w.ping.resolved = "203.0.113.80"
            w.ping.span = 300; w.ping.selectedDate = start.addingTimeInterval(80)
            let routeURL = root.appendingPathComponent("docs/examples/mtr-demo.csv")
            guard w.route.load(routeURL) else { fatalError("MTR fixture failed") }; w.route.mtr.selectedTTL = 2
            let speedDir = folder.appendingPathComponent("speed-demo"); try FileManager.default.createDirectory(at: speedDir, withIntermediateDirectories: true)
            let id = "314D08AF-3FD6-4A81-A9D5-F571E9446B1A"
            let meta = ["Session": id, "Provider": "cloudflare", "Started-At": CSVLog.timestamp(clock.addingTimeInterval(-30)), "Status": "completed", "Elapsed-Seconds": "26", "Scheduled-Payload-Bytes": "62400000", "Data-Note": "synthetic README demonstration"]
            var result = SpeedSummary(values: ["download": 196_000_000, "upload": 83_000_000, "latency": 24, "jitter": 4.8, "downLoadedLatency": 57, "upLoadedLatency": 112])
            var samples: [SpeedSample] = []
            for i in 0..<30 {
                let down = i < 18; let j = down ? i : i - 18
                let mbps = down ? 45 + Double(j) * 8 + 25 * sin(Double(j) * 1.4) : 25 + Double(j) * 5 + 12 * sin(Double(j) * 1.2)
                samples.append(SpeedSample(id: "\(i)", date: clock.addingTimeInterval(Double(i) - 30), kind: down ? "download" : "upload", bps: mbps * 1_000_000, duration: 90 + Double(j * 7)))
            }
            for kind in ["download", "upload"] {
                let rates = samples.filter { $0.kind == kind }.map(\.bps).sorted()
                result.values[kind] = rates[Int(ceil(Double(rates.count) * 0.9)) - 1]
            }
            try SpeedCSV.summary(meta, result).write(to: speedDir.appendingPathComponent("summary.csv"), atomically: true, encoding: .utf8)
            try SpeedCSV.samples(samples, session: id).write(to: speedDir.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)
            guard w.speed.load(speedDir) else { fatalError("speed fixture failed") }
            w.local.toggleObservation()
            for i in 0...300 { w.local.accept(snapshot(Double(i * 2 - 600))) }
            w.local.queryExit()
        } catch { fatalError("README fixtures: \(error)") }
    }
}

@main struct ReadmePreview: App {
    @StateObject private var workspaces: Workspaces
    init() {
        let w = Workspaces(); ReadmeFixtures.prepare(w); _workspaces = StateObject(wrappedValue: w)
    }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                Text("演示数据 · 非真实测量 / 扫描结果").font(.caption.weight(.medium)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity).padding(.vertical, 5).background(Color.orange.opacity(0.08))
                RootView().environmentObject(workspaces).environmentObject(workspaces.ping).environmentObject(workspaces.route).environmentObject(workspaces.speed)
            }.frame(minWidth: 1100, minHeight: 820)
        }.defaultSize(width: 1140, height: 900)
    }
}
