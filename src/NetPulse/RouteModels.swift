import Foundation

struct RouteProbe: Identifiable, Equatable {
    var id: Int
    var address: String?
    var rtt: Double?
    var annotation = ""
}
struct RouteHop: Identifiable, Equatable {
    var id: Int
    var probes: [RouteProbe]
    var raw: String
    var addresses: [String] { Array(Set(probes.compactMap(\.address))).sorted() }
    var received: Int { probes.filter { $0.rtt != nil }.count }
    var avg: Double? {
        let values = probes.compactMap(\.rtt)
        return values.isEmpty ? nil : values.reduce(0,+) / Double(values.count)
    }
    var state: String {
        if probes.contains(where: { !$0.annotation.isEmpty }) { return "异常响应 · 待核查" }
        if received == 0 { return "未回复 · 未知" }
        if addresses.count > 1 { return "多地址 · 待核查" }
        if received < probes.count { return "部分回复" }
        return "收到回复"
    }
}
struct GeoLocation: Equatable {
    var country: String
    var province: String
    var source: String
}
func validIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && (Int($0).map { (0...255).contains($0) } ?? false) }
}
func nonPublicAddress(_ value: String) -> Bool {
    let p = value.split(separator: ".").compactMap { Int($0) }
    guard p.count == 4 else { return false }
    return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 100 && (64...127).contains(p[1])) || (p[0] == 169 && p[1] == 254)
}
func routeTargetIP(_ line: String) -> String? {
    guard line.contains("traceroute to") else { return nil }
    return capture("\\(([0-9.]+)\\)", line).flatMap { validIPv4($0) ? $0 : nil }
}
func parseRouteHop(_ line: String) -> RouteHop? {
    guard let ttlText = capture("^\\s*([0-9]+)\\s+", line), let ttl = Int(ttlText), (1...255).contains(ttl) else { return nil }
    let body = line.replacingOccurrences(of: "^\\s*[0-9]+\\s+", with: "", options: .regularExpression)
    let regex = try! NSRegularExpression(pattern: "([0-9]{1,3}(?:\\.[0-9]{1,3}){3})|([0-9]+(?:\\.[0-9]+)?)\\s*ms|(\\*)|(![^\\s]+)")
    var ip: String?; var probes: [RouteProbe] = []
    for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
        func group(_ n: Int) -> String? { Range(match.range(at: n), in: body).map { String(body[$0]) } }
        if let address = group(1), validIPv4(address) { ip = address }
        else if let value = group(2), let rtt = Double(value), rtt.isFinite, let ip { probes.append(RouteProbe(id: probes.count, address: ip, rtt: rtt)) }
        else if group(3) != nil { probes.append(RouteProbe(id: probes.count)) }
        else if let annotation = group(4), !probes.isEmpty { probes[probes.count-1].annotation = annotation }
    }
    guard !probes.isEmpty, probes.count <= 100 else { return nil }
    return RouteHop(id: ttl, probes: probes, raw: line)
}
struct RouteArchive {
    var metadata: [String:String]
    var hops: [RouteHop]
    var geo: [String:GeoLocation]
    var invalid: Int
}
enum RouteCSV {
    static let columns = "ttl,sample,reply_ip,rtt_ms,outcome,annotation,country,province,geo_source"
    static func fields(_ line: String) throws -> [String] {
        var fields: [String] = []; var field = ""; var quoted = false; var closed = false
        let chars = Array(line); var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i+1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," { fields.append(field); field = ""; closed = false }
            else if c == "\"" && field.isEmpty && !closed { quoted = true }
            else { guard !closed && c != "\"" else { throw CocoaError(.fileReadCorruptFile) }; field.append(c) }
            i += 1
        }
        guard !quoted else { throw CocoaError(.fileReadCorruptFile) }
        fields.append(field); return fields
    }
    static func escape(_ value: String) -> String {
        let value = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return value.contains(",") || value.contains("\"") ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }
    static func encode(_ metadata: [String:String], hops: [RouteHop], geo: [String:GeoLocation]) -> String {
        var text = "# Type: NetPulse-Route\n# Route-Log-Version: 1\n"
        for key in metadata.keys.sorted() { text += "# \(key): \(metadata[key]!.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))\n" }
        text += columns + "\n"
        for hop in hops.sorted(by: { $0.id < $1.id }) {
            for p in hop.probes {
                let location = p.address.flatMap { geo[$0] }
                let values = [String(hop.id), String(p.id), p.address ?? "", p.rtt.map { String($0) } ?? "", p.rtt == nil ? "timeout" : "reply", p.annotation, location?.country ?? "", location?.province ?? "", location?.source ?? ""]
                text += values.map(escape).joined(separator: ",") + "\n"
            }
        }
        return text
    }
    static func decode(_ text: String) throws -> RouteArchive {
        var meta: [String:String] = [:]; var found = false; var bad = 0
        var rows: [Int:[RouteProbe]] = [:]; var geo: [String:GeoLocation] = [:]; var ids = Set<String>()
        for raw in text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { continue }
            if !found && line.hasPrefix("# "), let colon = line.firstIndex(of: ":") {
                meta[String(line[line.index(line.startIndex, offsetBy: 2)..<colon])] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces); continue
            }
            if !found { guard line == columns else { throw CocoaError(.fileReadCorruptFile) }; found = true; continue }
            guard let c = try? fields(line), c.count == 9, let ttl = Int(c[0]), (1...255).contains(ttl), let sample = Int(c[1]), (0..<100).contains(sample), !ids.contains("\(ttl):\(sample)"), ["reply","timeout"].contains(c[4]) else { bad += 1; continue }
            let rtt = Double(c[3])
            guard (c[2].isEmpty || validIPv4(c[2])), (c[4] == "reply" && validIPv4(c[2]) && rtt != nil && rtt!.isFinite && rtt! >= 0) || (c[4] == "timeout" && c[2].isEmpty && c[3].isEmpty) else { bad += 1; continue }
            ids.insert("\(ttl):\(sample)")
            rows[ttl,default:[]].append(RouteProbe(id: sample, address: c[2].isEmpty ? nil : c[2], rtt: rtt, annotation: c[5]))
            if !c[2].isEmpty && (!c[6].isEmpty || !c[7].isEmpty) { geo[c[2]] = GeoLocation(country: c[6], province: c[7], source: c[8]) }
        }
        guard found, meta["Type"] == "NetPulse-Route", meta["Route-Log-Version"] == "1", let target = meta["Target"], !target.isEmpty, target.count <= 253, target.range(of: "^[A-Za-z0-9][A-Za-z0-9.\\-]*$", options: .regularExpression) != nil, let date = meta["Started-At"], CSVLog.date(date) != nil else { throw CocoaError(.fileReadCorruptFile) }
        if let ip = meta["Target-IP"], !ip.isEmpty, !validIPv4(ip) { throw CocoaError(.fileReadCorruptFile) }
        if let gateway = meta["Gateway"], !gateway.isEmpty, !validIPv4(gateway) { throw CocoaError(.fileReadCorruptFile) }
        if let status = meta["Status"], !["idle","running","completed","not_reached","cancelled","timed_out","failed"].contains(status) { throw CocoaError(.fileReadCorruptFile) }
        let hops = rows.keys.sorted().map { RouteHop(id: $0, probes: rows[$0]!.sorted { $0.id < $1.id }, raw: "CSV 回放；原始行请查看配套诊断文本") }
        return RouteArchive(metadata: meta, hops: hops, geo: geo, invalid: bad)
    }
}
