import Foundation

@main struct MTRTests {
    @MainActor static func main() async throws {
        func check(_ v: @autoclosure () -> Bool, _ note: String) { precondition(v(), note) }
        let date = Date()
        func sample(_ id: Int, kind: String = "hop", ttl: Int = 1, ip: String = "127.0.0.1", rtt: Double? = 10, outcome: String = "reply", segment: Int = 1) -> MTRSample {
            MTRSample(id: id, date: date.addingTimeInterval(Double(id)), segment: segment, round: 1, kind: kind, ttl: ttl, address: ip, rtt: rtt, outcome: outcome)
        }
        let points = [sample(0), sample(1, rtt: 20), sample(2, ip: "", rtt: nil, outcome: "timeout"), sample(3, ip: "", rtt: nil, outcome: "error")]
        let stats = MTRStats(samples: points)
        check(stats.valid.count == 3 && stats.errors == 1 && stats.received == 2 && stats.avg == 15 && stats.p95 == 20, "stats exclude errors")
        check(abs(stats.loss! - 100.0 / 3) < 0.001 && stats.response! > 66, "weighted ratio by observed probe counts")
        check(MTRStats(samples: []).loss == nil && MTRStats(samples: []).p95 == nil, "missing stays missing")
        let meta = ["Session": UUID().uuidString, "Target": "localhost", "Target-IP": "127.0.0.1", "Started-At": CSVLog.timestamp(date), "Status": "paused"]
        let csv = MTRCSV.header(meta) + points.map(MTRCSV.row).joined()
        let archive = try MTRCSV.decode(csv.replacingOccurrences(of: "\n", with: "\r\n"))
        check(archive.samples.count == 4 && archive.samples[2].rtt == nil && archive.samples[2].outcome == "timeout", "CSV roundtrip and nulls")
        for bad in [csv + MTRCSV.row(points[0]), csv.replacingOccurrences(of: ",10.0,reply", with: ",nan,reply"), csv + "truncated,row", csv.replacingOccurrences(of: "NetPulse-MTR", with: "wrong")] {
            do { _ = try MTRCSV.decode(bad); fatalError("corrupt CSV accepted") } catch {}
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NetPulse-MTR-Tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = MTRStore(); m.logRoot = root; m.roundInterval = 0.2; m.hopLimit = 2
        m.begin("127.0.0.1")
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while (m.round < 2 || m.targetStats.received < 2) && m.running && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        check(m.running && m.round >= 2 && m.targetIP == "127.0.0.1" && m.targetStats.received >= 2, "real ICMP multi-round + independent target")
        let url = m.logURL!; let generation = m.token
        await m.stopAndWait()
        check(!m.running && !m.stopping && m.process == nil && m.state == "paused", "pause reclaims processes")
        let paused = try MTRStore.read(url)
        check(paused.metadata["Status"] == "paused" && paused.samples.contains { $0.kind == "hop" } && paused.samples.contains { $0.kind == "target" }, "readable persisted actual probes")
        let count = m.samples.count
        m.receive(Data("1 127.0.0.1 99 ms\n".utf8), generation: generation, round: m.round)
        check(m.samples.count == count, "late paused callback discarded")
        m.begin("127.0.0.1")
        check(m.running && m.segment == 2 && m.logURL == url, "resume new segment same log")
        let resumedCount = m.samples.count
        m.receive(Data("1 127.0.0.1 99 ms\n".utf8), generation: generation, round: m.round)
        check(m.samples.count == resumedCount, "previous generation isolated")
        await m.stopAndWait()
        let replay = MTRStore(); replay.load(try MTRStore.read(url), from: url)
        check(replay.imported && !replay.running && replay.process == nil && replay.segments == [1, 2], "offline import restores segments without probing")
        replay.chooseSegment(1); check(replay.window.allSatisfy { $0.segment == 1 }, "window isolates segment")
        let synthetic = MTRStore(traceExecutable: URL(fileURLWithPath: "/bin/sleep"), traceArguments: ["30"])
        synthetic.logRoot = root; synthetic.begin("127.0.0.1")
        synthetic.consume(" 1 192.0.2.1 10 ms")
        synthetic.consume(" 1 *")
        check(synthetic.segment == 1, "timeouts never imply route change")
        synthetic.consume(" 1 192.0.2.2 20 ms")
        check(synthetic.segment == 2 && synthetic.rows.first?.stats.addresses == ["192.0.2.2"] && synthetic.rows.first?.stats.avg == 20, "new address opens segment and excludes old node RTT")
        await synthetic.stopAndWait()
        let timeout = MTRStore(traceExecutable: URL(fileURLWithPath: "/bin/sleep"), traceArguments: ["30"])
        timeout.logRoot = root; timeout.roundBudget = 0.05; timeout.begin("127.0.0.1")
        try await Task.sleep(nanoseconds: 400_000_000)
        check(timeout.samples.contains { $0.outcome == "round_timeout" } && timeout.samples.allSatisfy { $0.outcome != "timeout" }, "round budget not fabricated packet loss")
        await timeout.stopAndWait()
        let route = RouteStore(geoDirectory: root.appendingPathComponent("geo"))
        check(route.load(url) && route.mode == .continuous && route.imported && !route.running, "existing route import dispatches MTR")
        route.reset(); check(!route.hasSession && route.mtr.samples.isEmpty, "workspace reset clears MTR")
        route.logRoot = root; route.mode = .continuous; route.hopLimit = 2; route.begin("127.0.0.1")
        let bridgeDeadline = ProcessInfo.processInfo.systemUptime + 3
        while route.targetIP.isEmpty && route.running && ProcessInfo.processInfo.systemUptime < bridgeDeadline { try await Task.sleep(nanoseconds: 30_000_000) }
        check(route.running && route.state == "running" && route.targetIP == "127.0.0.1" && route.statusTitle == "持续观察中", "route bridges live state and actual IP")
        await route.stopAndWait(); check(!route.running && route.state == "paused", "route stop waits for MTR")
        check(route.load(url) && route.imported, "paused route can import archive")
        let demo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/examples/mtr-demo.csv")
        check(route.load(demo) && route.mtr.segments == [1, 2] && route.message.contains("合成"), "synthetic demo clearly labeled")
        route.reset()
        print("PASS: MTR stats/P95/error exclusion, strict CSV, real loopback TTL sweeps/target ping, pause/resume, generation isolation, path segments, timeout semantics and offline route import")
    }
}
