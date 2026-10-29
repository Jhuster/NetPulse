import Foundation
@main struct SessionTests {
 @MainActor static func main() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/NetPulse-test-\(UUID().uuidString)")
    let s = Store(); s.logRoot = root; s.target = "127.0.0.1"
    s.begin()
    try await Task.sleep(nanoseconds: 6_500_000_000)
    s.stop()
    try await Task.sleep(nanoseconds: 2_000_000_000)
    assert(s.received >= 5 && s.errors == 0, "Real loopback probes must succeed: \(s.notice)")
    let before = s.samples.map { ($0.id, $0.avg, $0.jitter, $0.loss) }
    let count = s.sent; let url = s.logURL!
    s.reset(); s.load(url: url)
    assert(s.imported && s.sent == count)
    func close(_ a: Double?, _ b: Double?) -> Bool {
        if let a, let b { return abs(a-b) <= 0.000001 }; return a == nil && b == nil
    }
    for (a,b) in zip(before,s.samples) { assert(a.0 == b.id && close(a.1,b.avg) && close(a.2,b.jitter) && close(a.3,b.loss)) }
    // Updating a paused partial tail must not append duplicate windows.
    let tail = Store(); tail.logRoot = root; tail.target = "127.0.0.1"; tail.begin(); tail.stop()
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let tailURL = tail.logURL!
    if let w = tail.samples.last {
        let p = Probe(id: 100, sentAt: Date(), elapsed: Double(w.id)*5+0.5, rtt: 2, status: "reply", raw: "fixture")
        tail.consume(p); tail.flushWindows(force: true)
        let parsed = try CSVLog.read(String(contentsOf: tailURL, encoding: .utf8))
        assert(parsed.invalidRows == 0 && parsed.samples.count == tail.samples.count && parsed.samples.last?.sent == tail.samples.last?.sent)
    }
    tail.reset(); tail.target = "localhost"; tail.begin(); tail.stop()
    try await Task.sleep(nanoseconds: 1_500_000_000)
    assert(tail.logURL != tailURL)
    let newHeader = try String(contentsOf: tail.logURL!, encoding: .utf8)
    assert(newHeader.contains("# Target: localhost"))
    tail.reset()
    let closing = Store(); closing.logRoot = root; closing.target = "127.0.0.1"; closing.begin()
    let closingURL = closing.logURL!
    await closing.finishForExit()
    assert(!closing.running && closing.timer == nil && closing.work.isEmpty && closing.handle == nil && closing.csvHandle == nil)
    let finalCSV = try CSVLog.read(String(contentsOf: closingURL, encoding: .utf8))
    assert(finalCSV.samples.reduce(0) { $0 + $1.sent } >= 1)
    let diagnostic = try String(contentsOf: closingURL.deletingLastPathComponent().appendingPathComponent("diagnostics.txt"), encoding: .utf8)
    assert(diagnostic.contains("session_end"))
    let invalid = root.appendingPathComponent("invalid.jsonl")
    try Data("not-json\n".utf8).write(to: invalid)
    s.load(url: invalid)
    assert(s.notice.contains("无有效会话头"))
    print("PASS: real system ping, auto log, pause, import parity (\(count) probes), partial tail rewrite, new target/new file, exit drains in-flight probes and closes logs, invalid import; fixtures: \(root.path)")
 }
}
