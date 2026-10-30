import Foundation

@main struct WiFiDiagnosticsTests {
    @MainActor static func main() async throws {
        let fixture = WiFiDiagnosticsFixtures.scan()
        var value = WiFiDiagnosticsFixtures.snapshot()
        assert(fixture.networks[0].isCurrent(value.wifi) && !fixture.networks[1].isCurrent(value.wifi))
        value.wifi?.bssid = nil
        assert(!fixture.networks[0].isCurrent(value.wifi))
        assert(fixture.networks[0].snr == 45 && fixture.networks[2].snr == nil)
        var events = WiFiConnectionHistory(); value = WiFiDiagnosticsFixtures.snapshot(); events.append(value)
        assert(events.events.count == 1 && events.events[0].kind == "观测基线")
        value.date = value.date.addingTimeInterval(2); value.wifi?.rssi = -60; events.append(value)
        assert(events.events.count == 1)
        value.date = value.date.addingTimeInterval(2); value.wifi?.bssid = "02:00:00:00:00:02"; events.append(value)
        assert(events.events.last?.kind == "同名网络的接入点变化")
        value.date = value.date.addingTimeInterval(2); value.wifi?.bssid = nil; events.append(value)
        assert(events.events.last?.kind == "标识可读性变化")
        events.breakContinuity(); value.date = value.date.addingTimeInterval(2); value.wifi?.bssid = "02:00:00:00:00:03"; events.append(value)
        assert(events.events.last?.kind == "观测基线" && events.events.last!.detail.contains("中间过程未知"))
        value.date = value.date.addingTimeInterval(2); value.wifi?.channel = 44; events.append(value)
        assert(events.events.last?.kind == "信道变化")
        for i in 0..<220 { value.date = value.date.addingTimeInterval(2); value.wifi?.ssid = "Fixture-\(i)"; events.append(value) }
        assert(events.events.count == 200)
        let csv = WiFiDiagnosticsCSV.scan(fixture, stale: true)
        assert(csv.contains("# Status: stale") && csv.contains("Office, \"\"East\"\"\\nExample") && csv.contains(",,,未知"))
        assert(WiFiDiagnosticsCSV.events(events.events).contains("timestamp,event,detail"))
        let denied = LocalNetworkStore(scanner: { _ in fatalError("unauthorized scan") }, scanPermission: { false })
        denied.accept(WiFiDiagnosticsFixtures.snapshot()); denied.scanNearby()
        assert(!denied.scanBusy && denied.nearbyScan == nil && denied.scanMessage.contains("授权"))
        let count = ScanCounter()
        let store = LocalNetworkStore(scanner: { _ in count.increment(); Thread.sleep(forTimeInterval: 0.02); return WiFiDiagnosticsFixtures.scan() }, scanPermission: { true })
        store.accept(WiFiDiagnosticsFixtures.snapshot()); store.scanNearby(); store.scanNearby()
        await wait(store)
        assert(count.value == 1 && store.nearbyScan?.networks.count == 5 && !store.scanStale && !store.scanWaiting)
        var changed = WiFiDiagnosticsFixtures.snapshot(); changed.gateway4 = "192.0.2.1"; store.accept(changed)
        assert(store.scanStale)
        let timeout = LocalNetworkStore(scanner: { _ in Thread.sleep(forTimeInterval: 0.15); return WiFiDiagnosticsFixtures.scan() }, scanPermission: { true })
        timeout.scanTimeoutSeconds = 0.01; timeout.accept(WiFiDiagnosticsFixtures.snapshot()); timeout.scanNearby()
        try await Task.sleep(nanoseconds: 40_000_000)
        assert(timeout.scanBusy && !timeout.scanWaiting && timeout.scanMessage.contains("超时"))
        timeout.scanNearby(); await wait(timeout)
        assert(timeout.nearbyScan == nil && !timeout.scanBusy)
        let cancel = LocalNetworkStore(scanner: { _ in Thread.sleep(forTimeInterval: 0.05); return WiFiDiagnosticsFixtures.scan() }, scanPermission: { true })
        cancel.accept(WiFiDiagnosticsFixtures.snapshot()); cancel.scanNearby(); cancel.stopWaitingForScan(); await wait(cancel)
        assert(cancel.nearbyScan == nil)
        let raced = LocalNetworkStore(scanner: { _ in Thread.sleep(forTimeInterval: 0.05); return WiFiDiagnosticsFixtures.scan() }, scanPermission: { true })
        raced.accept(WiFiDiagnosticsFixtures.snapshot()); raced.scanNearby(); raced.accept(changed); await wait(raced)
        assert(raced.nearbyScan == nil)
        let failed = LocalNetworkStore(scanner: { _ in throw WiFiScanError.unavailable }, scanPermission: { true })
        failed.accept(WiFiDiagnosticsFixtures.snapshot()); failed.scanNearby(); await wait(failed)
        assert(failed.nearbyScan == nil && failed.scanMessage.contains("失败"))
        var off = WiFiDiagnosticsFixtures.snapshot(); off.wifi?.power = false
        failed.accept(off); failed.scanNearby(); assert(!failed.scanBusy && failed.scanMessage.contains("关闭"))
        let root = URL(fileURLWithPath: "/private/tmp/NetPulse-wifi-diagnostics-\(UUID().uuidString)")
        try store.writeExport(to: root)
        let exported = try String(contentsOf: root.appendingPathComponent("wifi-scan.csv"), encoding: .utf8)
        assert(exported.contains("# Status: stale") && exported.contains("Example Office"))
        assert(FileManager.default.fileExists(atPath: root.appendingPathComponent("wifi-events.csv").path))
        if ProcessInfo.processInfo.environment["NETPULSE_LIVE_WIFI_SCAN"] == "1" {
            let local = LocalNetworkReader.read(path: LocalPathInfo())
            if let wifi = local.wifi {
                do {
                    let result = try await Task.detached { try WiFiScanner.scan(interface: wifi.interface) }.value
                    print("LIVE: CoreWLAN returned \(result.networks.count) records; no identifiers printed")
                } catch { print("LIVE unavailable: \(error.localizedDescription)") }
            } else { print("LIVE unavailable: no readable Wi-Fi interface in this process") }
        }
        print("PASS: AP matching/nulls, baseline and observed changes without inferred roaming, pause gaps and retention, CSV escaping, permission gate, single scan, timeout, late/cancelled/raced results, errors, powered-off state and export")
    }
    @MainActor static func wait(_ store: LocalNetworkStore) async {
        let deadline = Date().addingTimeInterval(2)
        while store.scanBusy && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}
private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
