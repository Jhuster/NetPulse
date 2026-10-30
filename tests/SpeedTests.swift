import Foundation
import AppKit

@main struct SpeedTests {
    @MainActor static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
        for mb in [64, 256] {
            let plan = SpeedPlan.make(megabytes: mb)
            check(plan.declaredBytes <= plan.budget && plan.declaredBytes > plan.budget / 2, "payload plan within budget")
        }
        let filtered = SpeedSummary.validated(["download": 8_000_000, "upload": Double.nan, "latency": -1, "jitter": true])
        check(filtered.values == ["download": 8_000_000], "reject invalid/bool metrics")
        let system = try SpeedSummary.system(Data("{\"dl_throughput\":80000000,\"ul_throughput\":20000000,\"base_rtt\":12,\"dl_responsiveness\":700}".utf8))
        check(system.values["download"] == 80_000_000 && system.values["latency"] == 12 && system.values["dl_responsiveness"] == 700 && system.values["jitter"] == nil, "system units and missing values")
        do { _ = try SpeedSummary.system(Data("{\"error_domain\":\"failed\",\"dl_throughput\":8}".utf8)); fatalError("accepts system failure") } catch {}
        let metadata = ["Session": UUID().uuidString, "Provider": "cloudflare", "Started-At": SpeedCSV.timestamp(Date()), "Status": "stopped"]
        let point = SpeedSample(id: "download-1", date: Date(), kind: "download", bps: 123456, duration: 400)
        let text = SpeedCSV.summary(metadata, filtered)
        let decoded = try SpeedCSV.decode(summary: text, samples: SpeedCSV.samples([point], session: metadata["Session"]!))
        check(decoded.summary == filtered && decoded.samples.count == 1 && decoded.samples[0].duration == 400, "CSV roundtrip")
        do { _ = try SpeedCSV.decode(summary: text.replacingOccurrences(of: "8000000.0", with: "nan"), samples: SpeedCSV.samples([], session: metadata["Session"]!)); fatalError("accepts NaN") } catch {}
        do { _ = try SpeedCSV.decode(summary: text, samples: SpeedCSV.samples([point, point], session: metadata["Session"]!)); fatalError("accepts duplicate sample") } catch {}
        do { _ = try SpeedCSV.decode(summary: text, samples: SpeedCSV.samples([], session: UUID().uuidString)); fatalError("accepts mixed-session files") } catch {}
        do { _ = try SpeedCSV.decode(summary: text + "# Elapsed-Seconds: nan\n", samples: SpeedCSV.samples([], session: metadata["Session"]!)); fatalError("accepts unsafe elapsed metadata") } catch {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NetPulse-SpeedTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeedStore(root: root, resource: root)
        var events: [Bool] = []; store.onActivity = { events.append($0) }
        store.canStart = { false }; store.begin(); check(!store.running && store.logURL == nil, "scan guard prevents launch/log creation")
        store.canStart = { true }; store.begin()
        let folder = store.logURL!; let id = UUID(uuidString: folder.lastPathComponent)!
        check(store.running, "starts explicit session")
        store.receive(["session": UUID().uuidString, "summary": ["download": 99]], id: id)
        check(store.summary.values.isEmpty, "reject wrong session")
        store.receive(["session": id.uuidString, "event": "update", "summary": ["download": 1000]], id: id)
        check(store.summary.values["download"] == 1000, "accept session result")
        store.stop(); check(!store.running && events == [true, false], "single start/end event")
        check(store.stopping, "cleanup gate active")
        store.begin(); check(store.logURL == folder && !store.running, "cannot overlap old runner during cleanup")
        store.receive(["session": id.uuidString, "event": "finish", "summary": ["download": 999]], id: id)
        check(store.summary.values["download"] == 1000, "reject late callback")
        let archive = try SpeedStore.read(folder)
        check(archive.metadata["Status"] == "stopped" && archive.summary.values["download"] == 1000, "partial result persisted on stop")
        check(store.load(folder) && store.imported && !store.running, "offline import never starts engine")
        await store.stopAndWait()
        store.begin(); let second = store.logURL!
        check(second != folder && store.summary.values.isEmpty, "new run independent log/results")
        store.receive(["session": id.uuidString, "event": "finish", "summary": ["download": 999]], id: id)
        check(store.running && store.summary.values.isEmpty, "previous generation cannot finish new run")
        await store.stopAndWait()
        print("PASS: speed plans, schema, units, CSV, cancellation/session isolation, offline history")
    }
}
