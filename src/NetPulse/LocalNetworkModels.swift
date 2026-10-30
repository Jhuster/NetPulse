import Foundation
import Darwin

struct LocalPathInfo: Equatable, Sendable {
    var status = "等待系统状态"
    var available = false
    var kinds: [String] = []
    var interfaces: [String] = []
    var expensive = false
    var constrained = false
    var ipv4 = false
    var ipv6 = false
}
struct LocalInterfaceInfo: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: String
    var addresses: [String]
    var up: Bool
    var virtual: Bool
}
struct WiFiInfo: Equatable, Sendable {
    var interface: String
    var power: Bool
    var connected: Bool
    var ssid: String?
    var bssid: String?
    var rssi: Int?
    var noise: Int?
    var txRate: Double?
    var channel: Int?
    var band: String
    var width: String
    var phy: String
    var security: String
    var snr: Int? {
        guard let rssi, let noise, rssi >= noise else { return nil }
        return rssi - noise
    }
    var identity: String { [interface, ssid ?? "", bssid ?? "", connected ? "connected" : "disconnected", band, channel.map(String.init) ?? ""].joined(separator: "|") }
}
struct LocalNetworkSnapshot: Equatable, Sendable {
    var date = Date()
    var path = LocalPathInfo()
    var primaryInterface = ""
    var gateway4 = ""
    var gateway6 = ""
    var dns: [String] = []
    var proxies: [String] = []
    var interfaces: [LocalInterfaceInfo] = []
    var wifi: WiFiInfo?
    var issue = ""
    var lanAddresses: [String] {
        interfaces.filter { $0.up && !$0.virtual && !$0.addresses.isEmpty }
            .flatMap { item in item.addresses.filter { !$0.contains(":") }.map { "\($0) (\(item.id))" } }
    }
    var fingerprint: String {
        ([path.status, primaryInterface, gateway4, gateway6, wifi?.identity ?? ""] + path.kinds + dns + proxies
            + interfaces.filter(\.up).map { $0.id + ":" + $0.addresses.joined(separator: ",") }).joined(separator: "|")
    }
}
enum SignalLevel: String {
    case good = "强", fair = "一般", poor = "弱", unknown = "不可用"
    static func rssi(_ value: Int?) -> SignalLevel {
        guard let value, (-120 ... -1).contains(value) else { return .unknown }
        return value >= -60 ? .good : value >= -70 ? .fair : .poor
    }
    static func snr(_ value: Int?) -> SignalLevel {
        guard let value, value >= 0 else { return .unknown }
        return value >= 25 ? .good : value >= 15 ? .fair : .poor
    }
}
func wifiDBM(_ value: Int) -> Int? { (-120 ... -1).contains(value) ? value : nil }

struct WiFiSample: Identifiable, Sendable {
    var id: Int
    var date: Date
    var segment: Int
    var interface: String
    var rssi: Int?
    var noise: Int?
    var snr: Int?
    var txRate: Double?
}
struct WiFiHistory {
    private(set) var samples: [WiFiSample] = []
    private var serial = 0
    private var segment = 0
    private var identity = ""
    mutating func breakContinuity() { segment += 1 }
    mutating func append(_ snapshot: LocalNetworkSnapshot) {
        let wifi = snapshot.wifi
        let key = wifi?.identity ?? ""
        if key != identity || samples.last.map({ snapshot.date.timeIntervalSince($0.date) > 5 || snapshot.date <= $0.date }) == true || wifi?.rssi == nil || wifi?.noise == nil { segment += 1 }
        identity = key; serial += 1
        samples.append(WiFiSample(id: serial, date: snapshot.date, segment: segment, interface: wifi?.interface ?? "", rssi: wifi?.rssi, noise: wifi?.noise, snr: wifi?.snr, txRate: wifi?.txRate))
        samples.removeAll { snapshot.date.timeIntervalSince($0.date) > 600 }
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
    }
}

struct PublicExitInfo: Equatable, Sendable {
    var ip: String
    var isp: String
    var organization: String
    var asn: String
    var country: String
    var date: Date
    static func decode(_ data: Data, date: Date = Date()) throws -> PublicExitInfo {
        guard data.count <= 65_536, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = body["ip"] as? String, networkIP(ip) else { throw LocalNetworkError.invalidResponse }
        func string(_ key: String) -> String {
            String((body[key] as? String ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(200))
        }
        let asn = (body["asn"] as? NSNumber).map { "AS\($0.stringValue)" } ?? string("asn")
        return PublicExitInfo(ip: ip, isp: string("isp"), organization: string("organization"), asn: asn, country: string("country"), date: date)
    }
}
enum LocalNetworkError: LocalizedError {
    case invalidResponse, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "出口服务响应无效，请稍后重试"
        case .http(let code): return "出口服务返回 HTTP \(code)，请稍后重试"
        }
    }
}
func networkIP(_ ip: String) -> Bool {
    var v4 = in_addr(); var v6 = in6_addr()
    return ip.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
}

enum LocalNetworkExport {
    static func snapshot(_ value: LocalNetworkSnapshot, exit: PublicExitInfo?, stale: Bool) -> String {
        var lines = ["NetPulse 本机网络快照", "应用版本：0.1.0", "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)", "时间：\(ISO8601DateFormatter().string(from: value.date))", "系统路径：\(value.path.status)", "接入方式：\(value.path.kinds.joined(separator: " / "))", "默认接口：\(value.primaryInterface)", "IPv4 网关：\(value.gateway4)", "IPv6 网关：\(value.gateway6)", "默认 DNS：\(value.dns.joined(separator: ", "))", "系统代理：\(value.proxies.joined(separator: ", "))", ""]
        for item in value.interfaces { lines.append("接口 \(item.id) · \(item.name) · \(item.kind) · \(item.up ? "UP" : "DOWN")：\(item.addresses.joined(separator: ", "))") }
        if let w = value.wifi {
            lines += ["", "Wi-Fi 接口：\(w.interface)", "SSID：\(w.ssid ?? "不可用")", "BSSID：\(w.bssid ?? "不可用")", "RSSI：\(w.rssi.map(String.init) ?? "") dBm", "噪声：\(w.noise.map(String.init) ?? "") dBm", "SNR：\(w.snr.map(String.init) ?? "") dB", "Tx 协商速率：\(w.txRate.map(String.init(describing:)) ?? "") Mbps", "信道：\(w.channel.map(String.init) ?? "") · \(w.band) · \(w.width)", "PHY：\(w.phy) · 安全：\(w.security)"]
        }
        if let exit {
            lines += ["", "出口查询来源：IP.SB / https://api.ip.sb/geoip", "查询时间：\(ISO8601DateFormatter().string(from: exit.date))", "出口结果：\(stale ? "已过期，不代表当前出口" : "该 HTTPS 请求观察值")", "出口 IP：\(exit.ip)", "ISP：\(exit.isp)", "组织 / ASN：\(exit.organization) / \(exit.asn)", "国家参考：\(exit.country)"]
        }
        lines += ["", "系统路径可用不代表已验证互联网连通；协商速率不是实测网速。VPN/代理可能改变查询出口。", "SSID/BSSID 可能因未授权或系统限制而缺失。信号强弱不等于业务质量。"]
        return lines.joined(separator: "\n") + "\n"
    }
    static func signalCSV(_ samples: [WiFiSample]) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["# Type: NetPulse-WiFi", "# Version: 1", "# Interval: approximately 2 seconds; missing values are empty; segment changes break lines", "timestamp,segment,interface,rssi_dbm,noise_dbm,snr_db,tx_rate_mbps"]
        for s in samples {
            lines.append([formatter.string(from: s.date), String(s.segment), s.interface, s.rssi.map(String.init) ?? "", s.noise.map(String.init) ?? "", s.snr.map(String.init) ?? "", s.txRate.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
