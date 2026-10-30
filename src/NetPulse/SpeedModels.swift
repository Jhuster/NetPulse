import Foundation
import CoreFoundation

enum SpeedProvider: String, CaseIterable, Identifiable {
    case cloudflare, system
    var id: String { rawValue }
    var title: String { self == .cloudflare ? "Cloudflare" : "macOS 系统对照" }
    var version: String { self == .cloudflare ? "@cloudflare/speedtest 1.15.0" : "networkQuality · 系统版本相关" }
}
struct SpeedPlan {
    var budget: Int
    var measurements: [[String: Any]]
    var declaredBytes: Int { measurements.reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) * ($1["count"] as? Int ?? 0) } }
    static func make(megabytes: Int) -> SpeedPlan {
        let large = megabytes >= 256
        var measurements: [[String: Any]] = [["type": "latency", "numPackets": 2], ["type": "latency", "numPackets": 16]]
        let down = large ? [(100_000, 2), (1_000_000, 4), (8_000_000, 4), (32_000_000, 3)] : [(100_000, 2), (1_000_000, 3), (4_000_000, 4), (8_000_000, 2)]
        let up = large ? [(100_000, 2), (1_000_000, 4), (8_000_000, 4), (16_000_000, 4)] : [(100_000, 2), (1_000_000, 3), (4_000_000, 4), (4_000_000, 2)]
        for (type, rounds) in [("download", down), ("upload", up)] {
            for (bytes, count) in rounds { measurements.append(["type": type, "bytes": bytes, "count": count]) }
        }
        return SpeedPlan(budget: large ? 256_000_000 : 64_000_000, measurements: measurements)
    }
}
struct SpeedSample: Identifiable, Equatable {
    var id: String
    var date: Date
    var kind: String
    var bps: Double
    var duration: Double?
}
struct SpeedSummary: Equatable {
    var values: [String: Double] = [:]
    static let keys = ["download", "upload", "latency", "jitter", "downLoadedLatency", "upLoadedLatency", "responsiveness", "dl_responsiveness", "ul_responsiveness"]
    static func validated(_ value: [String: Any]) -> SpeedSummary {
        var result: [String: Double] = [:]
        for key in keys {
            if let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 { result[key] = n.doubleValue }
        }
        return SpeedSummary(values: result)
    }
    static func system(_ data: Data) throws -> SpeedSummary {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], (object["error_domain"] as? String ?? "").isEmpty, (object["error_code"] as? NSNumber)?.intValue ?? 0 == 0 else { throw CocoaError(.fileReadCorruptFile) }
        var mapped: [String: Any] = [:]
        for (key, source) in [("download", "dl_throughput"), ("upload", "ul_throughput"), ("latency", "base_rtt"), ("downLoadedLatency", "lud_foreign_dl_h2_req_resp"), ("upLoadedLatency", "lud_foreign_ul_h2_req_resp"), ("responsiveness", "responsiveness"), ("dl_responsiveness", "dl_responsiveness"), ("ul_responsiveness", "ul_responsiveness")] { mapped[key] = object[source] }
        let result = validated(mapped)
        guard result.values["download"] != nil || result.values["upload"] != nil else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
struct SpeedArchive {
    var metadata: [String: String]
    var summary: SpeedSummary
    var samples: [SpeedSample]
}
enum SpeedCSV {
    static func timestamp(_ date: Date) -> String { CSVLog.timestamp(date) }
    static func summary(_ metadata: [String: String], _ result: SpeedSummary) -> String {
        var lines = ["# Type: NetPulse-Speed", "# Version: 1"]
        for key in metadata.keys.sorted() { lines.append("# \(key): \(metadata[key]!.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))") }
        lines.append(SpeedSummary.keys.joined(separator: ","))
        lines.append(SpeedSummary.keys.map { result.values[$0].map { String($0) } ?? "" }.joined(separator: ","))
        return lines.joined(separator: "\n") + "\n"
    }
    static func samples(_ samples: [SpeedSample], session: String) -> String {
        var lines = ["# Type: NetPulse-Speed-Samples", "# Version: 1", "# Session: \(session)", "id,timestamp,kind,bps,duration_ms"]
        for p in samples { lines.append([p.id, timestamp(p.date), p.kind, String(p.bps), p.duration.map { String($0) } ?? ""].map(RouteCSV.escape).joined(separator: ",")) }
        return lines.joined(separator: "\n") + "\n"
    }
    static func decode(summary: String, samples: String) throws -> SpeedArchive {
        var metadata: [String: String] = [:]; var data: [String] = []
        for line in summary.components(separatedBy: .newlines).filter({ !$0.isEmpty }) {
            if line.hasPrefix("# "), let colon = line.firstIndex(of: ":") { metadata[String(line.dropFirst(2).prefix(upTo: colon))] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
            else { data.append(line) }
        }
        guard metadata["Type"] == "NetPulse-Speed", metadata["Version"] == "1", UUID(uuidString: metadata["Session"] ?? "") != nil,
              let provider = metadata["Provider"], SpeedProvider(rawValue: provider) != nil, CSVLog.date(metadata["Started-At"] ?? "") != nil,
              ["running", "completed", "stopped", "failed", "timed_out", "network_changed"].contains(metadata["Status"] ?? ""),
              data.count == 2, data[0] == SpeedSummary.keys.joined(separator: ",") else { throw CocoaError(.fileReadCorruptFile) }
        if let value = metadata["Elapsed-Seconds"] { guard let seconds = Double(value), seconds.isFinite, seconds >= 0, seconds <= 86_400 else { throw CocoaError(.fileReadCorruptFile) } }
        if let value = metadata["Scheduled-Payload-Bytes"] { guard let bytes = Int(value), bytes >= 0 else { throw CocoaError(.fileReadCorruptFile) } }
        var sampleMeta: [String: String] = [:]
        for line in samples.components(separatedBy: .newlines) where line.hasPrefix("# ") {
            if let colon = line.firstIndex(of: ":") { sampleMeta[String(line.dropFirst(2).prefix(upTo: colon))] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        }
        guard sampleMeta["Type"] == "NetPulse-Speed-Samples", sampleMeta["Version"] == "1", sampleMeta["Session"] == metadata["Session"] else { throw CocoaError(.fileReadCorruptFile) }
        let values = try RouteCSV.fields(data[1]); guard values.count == SpeedSummary.keys.count else { throw CocoaError(.fileReadCorruptFile) }
        var decoded: [String: Double] = [:]
        for (index, key) in SpeedSummary.keys.enumerated() where !values[index].isEmpty {
            guard let value = Double(values[index]), value.isFinite, value >= 0 else { throw CocoaError(.fileReadCorruptFile) }; decoded[key] = value
        }
        var points: [SpeedSample] = []; var ids = Set<String>()
        let rows = samples.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard rows.first == "id,timestamp,kind,bps,duration_ms", rows.count <= 2001 else { throw CocoaError(.fileReadCorruptFile) }
        for row in rows.dropFirst() {
            let f = try RouteCSV.fields(row)
            guard f.count == 5, !f[0].isEmpty, ids.insert(f[0]).inserted, let date = CSVLog.date(f[1]), ["download", "upload"].contains(f[2]), let bps = Double(f[3]), bps.isFinite, bps >= 0 else { throw CocoaError(.fileReadCorruptFile) }
            let duration = f[4].isEmpty ? nil : Double(f[4])
            guard f[4].isEmpty || (duration != nil && duration!.isFinite && duration! >= 0) else { throw CocoaError(.fileReadCorruptFile) }
            points.append(SpeedSample(id: f[0], date: date, kind: f[2], bps: bps, duration: duration))
        }
        return SpeedArchive(metadata: metadata, summary: SpeedSummary(values: decoded), samples: points)
    }
}
