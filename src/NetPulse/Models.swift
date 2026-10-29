import Foundation

struct Probe: Codable, Identifiable {
    var id: Int
    var sentAt: Date
    var elapsed: Double
    var rtt: Double?
    var status: String
    var raw: String
    var ip: String?
}
struct Record: Codable {
    var schema_version = 1
    var session_id: String
    var event_type: String
    var timestamp: Date
    var target: String?
    var probe: Probe?
    var message: String?
}
struct WindowSample: Identifiable {
    var id: Int
    var date: Date
    var probes: [Probe]
    var summary: WindowSummary? = nil
    var sent: Int { summary?.sent ?? probes.count }
    var received: Int { summary?.received ?? probes.filter { $0.status == "reply" }.count }
    var errorCount: Int { summary?.errors ?? probes.filter { $0.status != "reply" && $0.status != "timeout" }.count }
    var minimum: Double? { summary?.minimum ?? rtts.min() }
    var maximum: Double? { summary?.maximum ?? rtts.max() }
    var loss: Double? {
        if let summary { return summary.loss }
        let valid = probes.filter { $0.status == "reply" || $0.status == "timeout" }
        guard !valid.isEmpty else { return nil }
        return Double(valid.filter { $0.status == "timeout" }.count) / Double(valid.count) * 100
    }
    var rtts: [Double] { probes.compactMap(\.rtt) }
    var avg: Double? { if let summary { return summary.avg }; return rtts.isEmpty ? nil : rtts.reduce(0,+) / Double(rtts.count) }
    var jitter: Double? {
        if let summary { return summary.jitter }
        let sorted = probes.sorted { $0.id < $1.id }
        var diffs: [Double] = []
        for (a,b) in zip(sorted, sorted.dropFirst()) {
            if b.id == a.id + 1, let x = a.rtt, let y = b.rtt { diffs.append(abs(y-x)) }
        }
        return diffs.isEmpty ? nil : diffs.reduce(0,+) / Double(diffs.count)
    }
}
func capture(_ pattern: String, _ text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}
func parsePing(_ raw: String, id: Int, date: Date, elapsed: Double, exit: Int32) -> Probe {
    let rtt = capture("time[=<]([0-9.]+)\\s*ms", raw).flatMap(Double.init)
    let ip = capture("PING [^\\n]*\\(([0-9.]+)\\)", raw)
    let status: String
    if rtt != nil { status = "reply" }
    else if raw.contains("cannot resolve") || raw.contains("Unknown host") { status = "dns_error" }
    else if raw.contains("100.0% packet loss") || raw.contains("100% packet loss") { status = "timeout" }
    else { status = "error" }
    return Probe(id: id, sentAt: date, elapsed: elapsed, rtt: rtt, status: status, raw: raw, ip: ip)
}

struct LossInterval {
    let valid: Int
    let lost: Int
    let seconds: Int
    var percent: Double? { valid > 0 ? Double(lost) / Double(valid) * 100 : nil }
    // Sum packet counts, never average percentages from uneven/partial windows.
    static func summarize(_ samples: [WindowSample], endingAt end: Int) -> LossInterval {
        let lower = max(0, end - 12)
        let windows = samples.filter { $0.id >= lower && $0.id < end }
        let valid = windows.reduce(0) { $0 + $1.sent - $1.errorCount }
        let received = windows.reduce(0) { $0 + $1.received }
        return LossInterval(valid: valid, lost: valid - received, seconds: min(60, max(0, end * 5)))
    }
}
