import Foundation

@main struct RouteTests {
    @MainActor static func main() async throws {
        let normal = parseRouteHop(" 1  192.168.1.1  1.250 ms  2.000 ms  1.550 ms")!
        assert(normal.id == 1 && normal.received == 3 && normal.addresses == ["192.168.1.1"])
        let mixed = parseRouteHop(" 2  192.0.2.1  3.20 ms 192.0.2.2 4.30 ms *")!
        assert(mixed.probes.count == 3 && mixed.addresses.count == 2 && mixed.received == 2)
        let silent = parseRouteHop(" 3 * * *")!
        assert(silent.received == 0 && silent.avg == nil && silent.state == "未回复 · 未知")
        let unreachable = parseRouteHop(" 4 192.0.2.5 3.0 ms !H * *")!
        assert(unreachable.probes[0].annotation == "!H" && unreachable.state.contains("异常"))
        assert(parseRouteHop("error text") == nil && parseRouteHop(" 999 * * *") == nil)
        assert(routeTargetIP("traceroute to localhost (127.0.0.1), 30 hops max, 40 byte packets") == "127.0.0.1")
        assert(nonPublicAddress("100.64.0.1") && nonPublicAddress("192.168.1.1") && !nonPublicAddress("192.0.2.1"))
        let metadata = ["Target":"example.com", "Target-IP":"203.0.113.1", "Started-At":CSVLog.timestamp(Date()), "Status":"completed"]
        let geo = ["192.0.2.1":GeoLocation(country:"Example, Country", province:"Example \"Province\"", source:"fixture.csv")]
        let csv = RouteCSV.encode(metadata, hops:[normal,mixed,silent,unreachable], geo:geo)
        let archive = try RouteCSV.decode(csv.replacingOccurrences(of:"\n",with:"\r\n"))
        assert(archive.invalid == 0 && archive.hops.count == 4 && archive.hops[1].probes == mixed.probes && archive.geo == geo)
        let corrupt = try RouteCSV.decode(csv + "2,0,192.0.2.1,1,reply,,,,\n5,0,,nan,reply,,,,\nbroken,row\n")
        assert(corrupt.invalid == 3)
        do { _ = try RouteCSV.decode("bad\n"); assertionFailure("invalid route CSV must fail") } catch {}
        let root = URL(fileURLWithPath:"/private/tmp/NetPulse-route-test-\(UUID().uuidString)")
        let route = RouteStore(); route.logRoot = root; route.hopLimit = 2; route.timeBudget = 8
        route.begin("127.0.0.1")
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while route.running && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds:50_000_000) }
        assert(!route.running && route.state == "completed", "loopback traceroute failed: \(route.message)\n\(route.raw)")
        assert(route.targetIP == "127.0.0.1" && route.hops.first?.received == 3)
        let url = route.logURL!; let expected = route.hops
        let replay = RouteStore()
        assert(replay.load(url) && replay.imported && replay.process == nil && replay.hops.map(\.probes) == expected.map(\.probes))
        route.begin("127.0.0.1"); route.halt(); await route.stopAndWait()
        assert(!route.running && route.process == nil)
        let partialURL = route.logURL!
        assert(tryFile(partialURL).contains("Status: cancelled"))
        let geoFile = root.appendingPathComponent("geo.csv")
        try Data("ip,country,province\n192.0.2.1,\"Example, Country\",Province\n10.0.0.1,Country,Province\n".utf8).write(to:geoFile)
        let customGeo = RouteStore(geoDirectory: root.appendingPathComponent("geo-db"))
        assert(customGeo.loadGeo(geoFile) && customGeo.geo["192.0.2.1"]?.country == "Example, Country" && customGeo.geo["10.0.0.1"] == nil)
        assert(!replay.loadGeo(geoFile))
        let timeout = RouteStore(executableURL:URL(fileURLWithPath:"/bin/sleep"),arguments:["5"])
        timeout.logRoot = root; timeout.timeBudget = 0.05; timeout.begin("127.0.0.1")
        let timeoutDeadline = ProcessInfo.processInfo.systemUptime + 4
        while timeout.running && ProcessInfo.processInfo.systemUptime < timeoutDeadline { try await Task.sleep(nanoseconds:50_000_000) }
        assert(!timeout.running && timeout.state == "timed_out" && timeout.process == nil)
        assert(tryFile(timeout.logURL!).contains("Status: timed_out"))
        let incompleteFile = root.appendingPathComponent("incomplete.csv")
        try Data(RouteCSV.encode(metadata,hops:[normal],geo:[:]).utf8).write(to:incompleteFile)
        assert(replay.load(incompleteFile) && replay.state == "not_reached" && replay.message.contains("未恢复到目标回复"))
        var runningMetadata = metadata; runningMetadata["Status"] = "running"
        try Data(RouteCSV.encode(runningMetadata,hops:[normal],geo:[:]).utf8).write(to:incompleteFile)
        assert(replay.load(incompleteFile) && !replay.running && replay.process == nil && replay.statusTitle == "未完成扫描记录")
        let demo = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("docs/examples/route-demo.csv")
        assert(replay.load(demo) && replay.hops.count == 6 && replay.message.contains("合成演示") && replay.geoText("192.0.2.10") == "中国 · 上海")
        timeout.reset()
        route.reset(); replay.reset()
        print("PASS: route parsing/multipath/timeouts/unreachable, CSV round trip/corruption, real ICMP loopback, offline replay, cancellation, deadline, local geography, incomplete replay status; fixtures: \(root.path)")
    }
    static func tryFile(_ url: URL) -> String { (try? String(contentsOf:url,encoding:.utf8)) ?? "" }
}
