import Foundation

enum WiFiBand: String, CaseIterable, Identifiable, Sendable {
    case ghz2 = "2.4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz", unknown = "未知"
    var id: String { rawValue }
}
struct WiFiAccessPoint: Identifiable, Equatable, Sendable {
    var id: String
    var ssid: String?
    var bssid: String?
    var band: WiFiBand
    var channel: Int?
    var width: String
    var rssi: Int?
    var noise: Int?
    var security: String
    var snr: Int? {
        guard let rssi, let noise, rssi >= noise else { return nil }; return rssi - noise
    }
    func isCurrent(_ wifi: WiFiInfo?) -> Bool {
        guard let bssid, !bssid.isEmpty, let current = wifi?.bssid, wifi?.connected == true else { return false }
        return bssid.lowercased() == current.lowercased()
    }
}
struct WiFiScanResult: Sendable {
    var date: Date
    var interface: String
    var networks: [WiFiAccessPoint]
    var total: Int
}
enum WiFiScanError: LocalizedError {
    case unavailable, poweredOff
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Wi-Fi 接口不可用，请刷新本机信息"
        case .poweredOff: return "Wi-Fi 已关闭，请先在系统设置中开启"
        }
    }
}

struct WiFiConnectionEvent: Identifiable, Equatable, Sendable {
    var id: Int
    var date: Date
    var kind: String
    var detail: String
}
struct WiFiConnectionHistory {
    private(set) var events: [WiFiConnectionEvent] = []
    private var last: WiFiInfo?
    private var date: Date?
    private var serial = 0
    private var needsBaseline = true
    mutating func breakContinuity() { needsBaseline = true }
    mutating func append(_ value: LocalNetworkSnapshot) {
        let wifi = value.wifi
        let gap = date.map { value.date.timeIntervalSince($0) > 5 || value.date < $0 } ?? false
        defer { last = wifi; date = value.date; needsBaseline = false }
        if needsBaseline || gap {
            add(value.date, "观测基线", date == nil ? description(wifi) : "恢复观测；中间过程未知。" + description(wifi)); return
        }
        guard let old = last, let new = wifi else {
            if (last == nil) != (wifi == nil) { add(value.date, "接口信息变化", description(wifi)) }
            return
        }
        if old.interface != new.interface { add(value.date, "观察接口变化", "\(old.interface) → \(new.interface)；" + description(new)); return }
        if old.connected != new.connected || old.power != new.power {
            add(value.date, "连接状态变化", description(new)); return
        }
        guard old.connected && new.connected else { return }
        if let a = old.ssid, let b = new.ssid, a != b {
            add(value.date, "网络名称变化", "\(a) → \(b)"); return
        }
        if let a = old.bssid, let b = new.bssid, a.lowercased() != b.lowercased() {
            let sameName = old.ssid != nil && old.ssid == new.ssid
            add(value.date, sameName ? "同名网络的接入点变化" : "接入点变化", "\(a) → \(b)；未测量切换耗时"); return
        }
        if (old.ssid == nil) != (new.ssid == nil) || (old.bssid == nil) != (new.bssid == nil) {
            add(value.date, "标识可读性变化", "SSID / BSSID 的可读性发生变化，不能据此判定漫游"); return
        }
        if old.band != new.band || old.channel != new.channel {
            add(value.date, "信道变化", "\(old.band) / \(old.channel.map(String.init) ?? "未知") → \(new.band) / \(new.channel.map(String.init) ?? "未知")")
        }
    }
    private func description(_ wifi: WiFiInfo?) -> String {
        guard let wifi else { return "Wi-Fi 接口信息不可用" }
        if !wifi.power { return "\(wifi.interface) · Wi-Fi 已关闭" }
        if !wifi.connected { return "\(wifi.interface) · 未连接，或系统未提供连接信息" }
        return "\(wifi.interface) · \(wifi.ssid ?? "名称不可用") · BSSID \(wifi.bssid ?? "不可用") · \(wifi.band) / \(wifi.channel.map(String.init) ?? "未知")"
    }
    private mutating func add(_ date: Date, _ kind: String, _ detail: String) {
        serial += 1; events.append(WiFiConnectionEvent(id: serial, date: date, kind: kind, detail: detail))
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
}

enum WiFiDiagnosticsCSV {
    static func escape(_ text: String) -> String {
        let value = text.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        return value.contains(",") || value.contains("\"") ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }
    static func scan(_ result: WiFiScanResult, stale: Bool) -> String {
        let date = ISO8601DateFormatter().string(from: result.date)
        var lines = ["# Type: NetPulse-WiFi-Scan", "# Version: 1", "# Scanned-At: \(date)", "# Interface: \(result.interface)", "# Status: \(stale ? "stale" : "snapshot")", "# Note: primary channels only; no airtime or congestion measurement", "ssid,bssid,band,primary_channel,width,rssi_dbm,noise_dbm,snr_db,security"]
        for ap in result.networks {
            lines.append([ap.ssid ?? "", ap.bssid ?? "", ap.band.rawValue, ap.channel.map(String.init) ?? "", ap.width, ap.rssi.map(String.init) ?? "", ap.noise.map(String.init) ?? "", ap.snr.map(String.init) ?? "", ap.security].map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
    static func events(_ events: [WiFiConnectionEvent]) -> String {
        var lines = ["# Type: NetPulse-WiFi-Events", "# Version: 1", "# Note: observations about 2 seconds apart; no roaming duration measurement", "timestamp,event,detail"]
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for event in events { lines.append([formatter.string(from: event.date), event.kind, event.detail].map(escape).joined(separator: ",")) }
        return lines.joined(separator: "\n") + "\n"
    }
}
