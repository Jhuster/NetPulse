import Foundation

enum RouteMode: String, CaseIterable, Identifiable {
    case quick, continuous
    var id: String { rawValue }
    var title: String { self == .quick ? "快速查看" : "持续观察（MTR）" }
}
struct MTRSample: Identifiable, Equatable {
    var id: Int
    var date: Date
    var segment: Int
    var round: Int
    var kind: String
    var ttl: Int
    var address: String = ""
    var rtt: Double?
    var outcome: String
    var annotation: String = ""
    var country: String = ""
    var province: String = ""
    var source: String = ""
}
struct MTRStats {
    var samples: [MTRSample]
    var valid: [MTRSample] { samples.filter { $0.outcome == "reply" || $0.outcome == "timeout" } }
    var received: Int { valid.filter { $0.outcome == "reply" }.count }
    var errors: Int { samples.filter { $0.outcome == "error" }.count }
    var loss: Double? { valid.isEmpty ? nil : Double(valid.count - received) / Double(valid.count) * 100 }
    var response: Double? { loss.map { 100 - $0 } }
    var rtts: [Double] { valid.filter { $0.outcome == "reply" }.compactMap(\.rtt) }
    var avg: Double? { rtts.isEmpty ? nil : rtts.reduce(0,+) / Double(rtts.count) }
    var p95: Double? {
        let v = rtts.sorted(); return v.isEmpty ? nil : v[max(0, Int(ceil(Double(v.count) * 0.95)) - 1)]
    }
    var addresses: [String] { Array(Set(valid.filter { $0.outcome == "reply" }.map(\.address))).sorted() }
}
struct MTRHopRow: Identifiable {
    var id: Int
    var stats: MTRStats
}
struct MTRLossPoint: Identifiable {
    var id: Int
    var date: Date
    var loss: Double
}
struct MTRArchive {
    var metadata: [String: String]
    var samples: [MTRSample]
}
enum MTRCSV {
    static let columns = "id,timestamp,segment,round,kind,ttl,reply_ip,rtt_ms,outcome,annotation,country,province,geo_source"
    static let events: Set<String> = ["segment", "round_end", "round_timeout", "pause", "resume", "failed"]
    static let statuses: Set<String> = ["running", "paused", "pausing", "failed"]
    static func meta(_ values: [String: String]) -> String {
        values.keys.sorted().map { "# \($0): \(values[$0]!.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))\n" }.joined()
    }
    static func header(_ values: [String: String]) -> String { meta(["Type": "NetPulse-MTR", "MTR-Log-Version": "1"].merging(values) { _, b in b }) + columns + "\n" }
    static func row(_ p: MTRSample) -> String {
        [String(p.id), CSVLog.timestamp(p.date), String(p.segment), String(p.round), p.kind, String(p.ttl), p.address, p.rtt.map(String.init(describing:)) ?? "", p.outcome, p.annotation, p.country, p.province, p.source].map(RouteCSV.escape).joined(separator: ",") + "\n"
    }
    static func decode(_ text: String) throws -> MTRArchive {
        guard text.utf8.count <= 50_000_000 else { throw CocoaError(.fileReadTooLarge) }
        var metadata: [String: String] = [:]; var found = false; var points: [MTRSample] = []; var last = -1
        var previousDate = Date.distantPast; var previousSegment = 0; var previousRound = 0
        for raw in text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines) where !raw.isEmpty {
            if raw.hasPrefix("# "), let colon = raw.firstIndex(of: ":") {
                metadata[String(raw[raw.index(raw.startIndex, offsetBy: 2)..<colon])] = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces); continue
            }
            if !found { guard raw == columns else { throw CocoaError(.fileReadCorruptFile) }; found = true; continue }
            let c = try RouteCSV.fields(raw)
            guard c.count == 13, let id = Int(c[0]), id > last, let date = CSVLog.date(c[1]), date >= previousDate,
                  let segment = Int(c[2]), segment >= max(1, previousSegment), segment <= 1_000_000,
                  let round = Int(c[3]), round >= previousRound, round <= 1_000_000,
                  ["hop", "target", "event"].contains(c[4]), let ttl = Int(c[5]), (0...30).contains(ttl),
                  c[6].isEmpty || validIPv4(c[6]), points.count < 250_000 else { throw CocoaError(.fileReadCorruptFile) }
            let rtt = c[7].isEmpty ? nil : Double(c[7])
            guard c[7].isEmpty || (rtt != nil && rtt!.isFinite && rtt! >= 0 && rtt! <= 60_000) else { throw CocoaError(.fileReadCorruptFile) }
            if c[4] == "event" { guard ttl == 0, rtt == nil, c[6].isEmpty, events.contains(c[8]) else { throw CocoaError(.fileReadCorruptFile) } }
            else {
                guard c[4] == "hop" ? ttl > 0 : ttl == 0, ["reply", "timeout", "error"].contains(c[8]),
                      c[8] == "reply" ? (rtt != nil && !c[6].isEmpty) : (rtt == nil && c[6].isEmpty) else { throw CocoaError(.fileReadCorruptFile) }
            }
            points.append(MTRSample(id: id, date: date, segment: segment, round: round, kind: c[4], ttl: ttl, address: c[6], rtt: rtt, outcome: c[8], annotation: c[9], country: c[10], province: c[11], source: c[12]))
            last = id; previousDate = date; previousSegment = segment; previousRound = round
        }
        guard found, metadata["Type"] == "NetPulse-MTR", metadata["MTR-Log-Version"] == "1", UUID(uuidString: metadata["Session"] ?? "") != nil,
              let target = metadata["Target"], !target.isEmpty, target.count <= 253,
              CSVLog.date(metadata["Started-At"] ?? "") != nil, statuses.contains(metadata["Status"] ?? ""),
              (metadata["Target-IP"] ?? "").isEmpty || validIPv4(metadata["Target-IP"]!) else { throw CocoaError(.fileReadCorruptFile) }
        return MTRArchive(metadata: metadata, samples: points)
    }
}
