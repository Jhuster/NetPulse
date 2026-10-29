import Foundation

struct WindowSummary {
    var sent: Int
    var received: Int
    var errors: Int
    var loss: Double?
    var avg: Double?
    var jitter: Double?
    var minimum: Double?
    var maximum: Double?
}
struct CSVSession {
    var id: String
    var target: String
    var start: Date
    var samples: [WindowSample]
    var invalidRows: Int
}
enum CSVLog {
    static let columns = "timestamp,loss_pct,rtt_avg_ms,jitter_ms,sent,received,errors,window_status,rtt_status,jitter_status,rtt_min_ms,rtt_max_ms,window_index"
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func header(id: String, target: String, start: Date) -> String {
        """
        # NetPulse-Version: 0.1.0
        # Log-Version: 2
        # Session-ID: \(id)
        # Target: \(target)
        # Started-At: \(timestamp(start))
        # System: macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        # Window-Seconds: 5
        # Probe-Interval-Seconds: 1
        # Jitter: mean absolute adjacent RTT difference; loss/gap breaks pairs
        # Missing-Values: empty numeric fields; see status columns
        # Loss: timeout / (sent - errors) * 100; sent counts completed probes
        \(columns)

        """
    }
    static func row(_ w: WindowSample) -> String {
        func n(_ v: Double?) -> String {
            guard let v else { return "" }
            let text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), v)
            return text.replacingOccurrences(of: "0+$", with: "", options: .regularExpression).replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        }
        let rttStatus = w.avg != nil ? "ok" : (w.errorCount == w.sent ? "probe_error" : "all_lost")
        let values = [timestamp(w.date), n(w.loss), n(w.avg), n(w.jitter), String(w.sent), String(w.received), String(w.errorCount), w.sent == 5 ? "complete" : "partial", rttStatus, w.jitter == nil ? "insufficient_pairs" : "ok", n(w.minimum), n(w.maximum), String(w.id)]
        return values.joined(separator: ",") + "\n"
    }
    static func read(_ text: String) throws -> CSVSession {
        var meta: [String:String] = [:]; var samples: [WindowSample] = []; var bad = 0
        var foundHeader = false; var ids = Set<Int>()
        for line in text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines) where !line.isEmpty {
            if line.hasPrefix("# ") {
                if !foundHeader, let colon = line.firstIndex(of: ":") { meta[String(line[line.index(line.startIndex, offsetBy: 2)..<colon])] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
                continue
            }
            if !foundHeader {
                guard line == columns else { throw CocoaError(.fileReadCorruptFile) }
                foundHeader = true; continue
            }
            let c = line.components(separatedBy: ",")
            guard c.count == 13, let time = date(c[0]), let sent = Int(c[4]), let received = Int(c[5]), let errors = Int(c[6]), let index = Int(c[12]),
                  index >= 0, index < 6_307_200, sent > 0, sent <= 100_000, received >= 0, received <= sent, errors >= 0, errors <= sent, received + errors <= sent,
                  ["complete","partial"].contains(c[7]), ["ok","all_lost","probe_error"].contains(c[8]), ["ok","insufficient_pairs"].contains(c[9]) else { bad += 1; continue }
            let nums = [1,2,3,10,11].map { c[$0].isEmpty ? nil : Double(c[$0]) }
            guard zip([1,2,3,10,11], nums).allSatisfy({ c[$0.0].isEmpty || ($0.1 != nil && $0.1!.isFinite && $0.1! >= 0) }),
                  nums[0] == nil || nums[0]! <= 100,
                  (received > 0) == (nums[1] != nil), (c[8] == "ok") == (nums[1] != nil), (c[9] == "ok") == (nums[2] != nil),
                  (sent > errors) == (nums[0] != nil), !ids.contains(index) else { bad += 1; continue }
            if let loss = nums[0], abs(loss - Double(sent-errors-received)/Double(sent-errors)*100) > 0.000001 { bad += 1; continue }
            ids.insert(index)
            let summary = WindowSummary(sent: sent, received: received, errors: errors, loss: nums[0], avg: nums[1], jitter: nums[2], minimum: nums[3], maximum: nums[4])
            samples.append(WindowSample(id: index, date: time, probes: [], summary: summary))
        }
        guard foundHeader, meta["Log-Version"] == "2", meta["Window-Seconds"] == "5", let id = meta["Session-ID"], !id.isEmpty, let target = meta["Target"], !target.isEmpty, let start = meta["Started-At"].flatMap(date) else { throw CocoaError(.fileReadCorruptFile) }
        return CSVSession(id: id, target: target, start: start, samples: samples.sorted { $0.id < $1.id }, invalidRows: bad)
    }
}
