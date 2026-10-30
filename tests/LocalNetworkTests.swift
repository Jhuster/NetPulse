import Foundation

@main struct LocalNetworkTests {
    @MainActor static func main() async throws {
        assert(wifiDBM(0) == nil && wifiDBM(-150) == nil && wifiDBM(-55) == -55)
        assert(SignalLevel.rssi(nil) == .unknown && SignalLevel.rssi(0) == .unknown)
        assert(SignalLevel.rssi(-60) == .good && SignalLevel.rssi(-61) == .fair && SignalLevel.rssi(-70) == .fair && SignalLevel.rssi(-71) == .poor)
        assert(SignalLevel.snr(25) == .good && SignalLevel.snr(24) == .fair && SignalLevel.snr(14) == .poor)
        var sample = fixture()
        assert(sample.wifi?.snr == 40)
        sample.wifi?.noise = -30; assert(sample.wifi?.snr == nil)
        sample.wifi?.noise = nil; assert(sample.wifi?.snr == nil)
        sample = fixture()
        var history = WiFiHistory(); history.append(sample)
        sample.date = sample.date.addingTimeInterval(2); history.append(sample)
        assert(history.samples[0].segment == history.samples[1].segment)
        let originalSegment = history.samples.last!.segment
        history.breakContinuity(); sample.date = sample.date.addingTimeInterval(1); history.append(sample)
        assert(history.samples.last!.segment != originalSegment)
        history = WiFiHistory(); sample = fixture(); history.append(sample)
        sample.date = sample.date.addingTimeInterval(2); history.append(sample)
        sample.date = sample.date.addingTimeInterval(8); history.append(sample)
        assert(history.samples[1].segment != history.samples[2].segment)
        sample.wifi?.rssi = nil; sample.date = sample.date.addingTimeInterval(2); history.append(sample)
        assert(history.samples.last?.rssi == nil)
        sample.wifi?.rssi = -52; sample.date = sample.date.addingTimeInterval(2); history.append(sample)
        assert(history.samples[2].segment != history.samples[4].segment)
        sample.wifi?.ssid = "Another-Fixture"; sample.date = sample.date.addingTimeInterval(2); history.append(sample)
        assert(history.samples[4].segment != history.samples[5].segment)
        for _ in 0..<400 { sample.date = sample.date.addingTimeInterval(2); history.append(sample) }
        assert(history.samples.count <= 301)
        assert(networkIP("1.1.1.1") && networkIP("2001:db8::1") && !networkIP("999.1.1.1") && !networkIP("nan"))
        let data = Data(#"{"ip":"198.51.100.9","isp":"Example ISP","organization":"Example Network","asn":64500,"country":"Example"}"#.utf8)
        let exit = try PublicExitInfo.decode(data)
        assert(exit.asn == "AS64500" && exit.isp == "Example ISP")
        let minimal = try PublicExitInfo.decode(Data(#"{"ip":"2001:db8::1"}"#.utf8))
        assert(minimal.isp.isEmpty && minimal.organization.isEmpty)
        for invalid in ["{}", "<html>error</html>", #"{"ip":"1.2.999.1"}"#, #"{"ip":10}"#] {
            do { _ = try PublicExitInfo.decode(Data(invalid.utf8)); assertionFailure("invalid public response") } catch {}
        }
        let counter = QueryCounter()
        let store = LocalNetworkStore(reader: { _ in fixture() }, fetchExit: {
            await counter.increment()
            try await Task.sleep(nanoseconds: 30_000_000)
            return exit
        })
        store.accept(fixture())
        let initialQueries = await counter.count
        assert(initialQueries == 0 && store.exitInfo == nil)
        store.queryExit()
        await waitForExit(store)
        assert(store.exitInfo == exit && !store.exitStale && !store.queryingExit)
        var changed = fixture(); changed.gateway4 = "192.0.2.254"
        store.accept(changed)
        assert(store.exitStale && store.lastChange != nil)
        store.queryExit()
        changed.gateway4 = "192.0.2.253"; store.accept(changed)
        try await Task.sleep(nanoseconds: 60_000_000)
        assert(store.exitStale && !store.queryingExit && store.exitInfo == exit)
        let slow = LocalNetworkStore(reader: { _ in Thread.sleep(forTimeInterval: 0.03); return fixture() }, fetchExit: { exit })
        slow.refresh(); slow.stop()
        try await Task.sleep(nanoseconds: 60_000_000)
        assert(slow.snapshot.interfaces.isEmpty && slow.history.samples.isEmpty)
        slow.toggleObservation()
        assert(!slow.observationEnabled)
        slow.enter()
        assert(!slow.observing)
        slow.stop()
        let failing = LocalNetworkStore(fetchExit: { throw LocalNetworkError.http(429) })
        failing.queryExit(); await waitForExit(failing)
        assert(failing.exitInfo == nil && failing.exitMessage.contains("429"))
        let root = URL(fileURLWithPath: "/private/tmp/NetPulse-local-tests-\(UUID().uuidString)")
        try store.writeExport(to: root)
        let text = try String(contentsOf: root.appendingPathComponent("network.txt"), encoding: .utf8)
        let csv = try String(contentsOf: root.appendingPathComponent("wifi.csv"), encoding: .utf8)
        assert(text.contains("Fixture-WiFi") && text.contains("已过期") && text.contains("IP.SB"))
        assert(csv.contains("timestamp,segment,interface,rssi_dbm,noise_dbm,snr_db,tx_rate_mbps") && csv.contains(",-50,-90,40,600.00"))
        do { try store.writeExport(to: root); assertionFailure("must not overwrite existing export") } catch {}
        let real = LocalNetworkReader.read(path: LocalPathInfo())
        assert(Set(real.interfaces.map(\.id)).count == real.interfaces.count)
        assert(real.wifi?.rssi != 0 && real.wifi?.noise != 0)
        print("PASS: real local read (\(real.interfaces.count) interfaces; Wi-Fi interface \(real.wifi == nil ? "unavailable" : "present")); no permission requested")
        if ProcessInfo.processInfo.environment["NETPULSE_LIVE_LOCAL_EXIT"] == "1" {
            let info = try await LocalNetworkStore.fetchPublicExit()
            assert(networkIP(info.ip))
            print("PASS: real HTTPS public exit query; valid IP, ISP field \(info.isp.isEmpty ? "absent" : "present"), ASN \(info.asn.isEmpty ? "absent" : "present")")
        }
        store.stop(); failing.stop()
        print("PASS: signal thresholds/nulls/SNR, history segmentation/gaps/retention, IPv4/IPv6 and public response parsing, on-demand query only, stale/raced queries, stopped reads, failure states, readable snapshot/CSV export")
    }
    @MainActor static func waitForExit(_ store: LocalNetworkStore) async {
        let deadline = Date().addingTimeInterval(2)
        while store.queryingExit && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
    nonisolated static func fixture() -> LocalNetworkSnapshot {
        var value = LocalNetworkSnapshot()
        value.path = LocalPathInfo(status: "系统路径可用", available: true, kinds: ["Wi-Fi"], interfaces: ["en0"], ipv4: true)
        value.primaryInterface = "en0"; value.gateway4 = "192.0.2.1"; value.dns = ["192.0.2.53"]
        value.interfaces = [LocalInterfaceInfo(id: "en0", name: "Fixture Wi-Fi", kind: "Wi-Fi", addresses: ["192.0.2.10", "2001:db8::10"], up: true, virtual: false)]
        value.wifi = WiFiInfo(interface: "en0", power: true, connected: true, ssid: "Fixture-WiFi", bssid: "00:00:00:00:00:01", rssi: -50, noise: -90, txRate: 600, channel: 36, band: "5 GHz", width: "80 MHz", phy: "802.11ax", security: "WPA2")
        return value
    }
}
private actor QueryCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
