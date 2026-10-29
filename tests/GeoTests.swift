import Foundation

@main struct GeoTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/NetPulse-geo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests/fixtures/GeoIP2-City-Test.mmdb")
        let downloadPage = "https://download.db-ip.com/free/dbip-city-lite-2026-09.mmdb.gz https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz"
        try check(try GeoDownload.archiveURL(in: downloadPage).lastPathComponent == "dbip-city-lite-2026-10.mmdb.gz")
        for html in ["http://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz", "https://evil.example/dbip-city-lite-2026-10.mmdb.gz", "https://download.db-ip.com/free/dbip-city-lite-2026-10.csv.gz"] {
            do { _ = try GeoDownload.archiveURL(in: html); assertionFailure("untrusted download URL") } catch {}
        }
        let cancelled = GeoDownload(destination: root.appendingPathComponent("cancelled.gz")) { _, _ in }
        cancelled.cancel()
        do { _ = try await cancelled.download(URL(string: "https://download.db-ip.com/free/dbip-city-lite-2026-10.mmdb.gz")!); assertionFailure("cancelled download must fail") }
        catch let error as URLError { assert(error.code == .cancelled) }
        assert(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.gz").path))
        if ProcessInfo.processInfo.environment["NETPULSE_LIVE_GEO_DOWNLOAD"] == "1" {
            let downloadStore = RouteStore(geoDirectory: root.appendingPathComponent("production"))
            downloadStore.downloadGeoDatabase()
            let deadline = Date().addingTimeInterval(180)
            while downloadStore.geoLoading && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            guard let production = downloadStore.geoDatabase else { fatalError("download/install failed: \(downloadStore.geoMessage)") }
            assert(!downloadStore.geoDownloading && downloadStore.geoDownloadProgress == nil)
            try check(try production.lookup("8.8.8.8")?.country.isEmpty == false)
            print("PASS: one-click store workflow, real official download, gzip validation, production MMDB install and lookup · \(production.source)")
        }
        let real = try GeoDatabase(url: fixture)
        try check(try real.lookup("81.2.69.160")?.country == "英国")
        try check(try real.lookup("81.2.69.160")?.province == "英格兰")
        try check(try real.lookup("81.2.69.191")?.province == "英格兰")
        try check(try real.lookup("89.160.20.128")?.province == "Östergötland County")
        try check(try real.lookup("1.1.1.1") == nil)
        for ip in ["127.0.0.1", "10.0.0.1", "100.64.0.1", "192.168.1.1", "0.0.0.0", "224.0.0.1", "198.18.0.1", "192.0.2.1", "203.0.113.1", "invalid"] {
            try check(try real.lookup(ip) == nil)
        }
        // Exercise node layouts independently of the upstream IPv6/28-bit fixture.
        for size in [24, 28, 32] {
            let reader = try GeoDatabase(data: database(recordSize: size, record: city))
            try check(try reader.lookup("1.2.3.4")?.country == "中国")
            try check(try reader.lookup("1.2.3.4")?.province == "上海")
            try check(try reader.lookup("223.5.5.5") == nil)
        }
        let countryOnly = try GeoDatabase(data: database(record: map([("country", map([("iso_code", string("US"))]))])))
        try check(try countryOnly.lookup("1.1.1.1")?.country == "美国")
        try check(try countryOnly.lookup("1.1.1.1")?.province == "")
        for broken in [Data(), Data("not a database".utf8), database(record: [0x20, 0]), database(record: [0x5f, 0xff, 0xff, 0xff])] {
            do { let db = try GeoDatabase(data: broken); _ = try db.lookup("1.1.1.1"); assertionFailure("corruption must fail") } catch {}
        }
        // All pointer-width encodings and payload-size encodings.
        for (bytes, target) in [([UInt8(0x20), 10], 10), ([0x28, 0, 0], 2048), ([0x30, 0, 0, 0], 526336), ([0x38, 0, 0, 0, 10], 10)] {
            var record = bytes
            record += Array(repeating: 0, count: target - record.count)
            record += city
            try check(try GeoDatabase(data: database(record: record)).lookup("1.1.1.1")?.province == "上海")
        }
        for length in [29, 300, 66000] {
            let record = map([("country", map([("names", map([("en", string(String(repeating: "x", count: length)))]))]))])
            try check(try GeoDatabase(data: database(record: record)).lookup("1.1.1.1")?.country.count == length)
        }
        // Pointer fan-out must not bypass the per-lookup value budget.
        var fanout: [UInt8] = [2, 4, 0x20, 6, 0x20, 6]
        for _ in 0..<15 {
            let next = fanout.count + 6
            fanout += [2, 4, 0x20 | UInt8(next >> 8), UInt8(next & 255), 0x20 | UInt8(next >> 8), UInt8(next & 255)]
        }
        fanout += string("leaf")
        do { _ = try GeoDatabase(data: database(record: fanout)).lookup("1.1.1.1"); assertionFailure("expanded value budget") } catch {}

        let installedDirectory = root.appendingPathComponent("installed")
        let store = RouteStore(geoDirectory: installedDirectory); store.logRoot = root.appendingPathComponent("logs")
        await store.installGeoDatabase(fixture)
        assert(store.geoDatabase != nil && !store.geoLoading)
        store.hops = [parseRouteHop("1 81.2.69.160 1 ms 1 ms 1 ms")!]
        store.resolveGeography()
        await settle(store)
        assert(store.geoText("81.2.69.160") == "英国 · 英格兰")
        let originalSource = store.geo["81.2.69.160"]!.source
        let override = root.appendingPathComponent("override.csv")
        try Data("ip,country,province\n81.2.69.160,Custom,Override\n".utf8).write(to: override)
        assert(store.loadGeo(override))
        await settle(store)
        assert(store.geo["81.2.69.160"]?.province == "Override")
        let restored = RouteStore(geoDirectory: installedDirectory)
        await settle(restored)
        assert(restored.geoDatabase?.source == store.geoDatabase?.source)
        let broken = root.appendingPathComponent("bad.mmdb")
        try Data("bad".utf8).write(to: broken)
        await store.installGeoDatabase(broken)
        assert(store.geoDatabase?.source == restored.geoDatabase?.source && store.geoMessage.contains("失败"))
        try check(try GeoDatabase(url: GeoDatabaseInstaller.databaseURL(in: installedDirectory)).source == originalSource)
        // gzip import and atomic replacement of an existing database.
        let gzip = Process(); let pipe = Pipe()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); gzip.arguments = ["-c", fixture.path]; gzip.standardOutput = pipe
        try gzip.run(); let compressed = pipe.fileHandleForReading.readDataToEndOfFile(); gzip.waitUntilExit()
        let gz = root.appendingPathComponent("database.mmdb.gz"); try compressed.write(to: gz)
        await store.installGeoDatabase(gz)
        assert(!store.geoLoading && !store.geoMessage.contains("失败"))
        let meta = ["Target":"example.com", "Target-IP":"81.2.69.160", "Started-At":CSVLog.timestamp(Date()), "Geo-Source":store.geoSource]
        let log = root.appendingPathComponent("route.csv")
        try Data(RouteCSV.encode(meta, hops: store.hops, geo: store.geo).utf8).write(to: log)
        assert(store.load(log))
        let snapshot = store.geo
        store.resolveGeography()
        assert(!store.loadGeo(override))
        await store.installGeoDatabase(fixture)
        await settle(store)
        assert(store.geo == snapshot && store.imported)
        // Results queued before a reset must never leak into the next session.
        restored.hops = [parseRouteHop("1 81.2.69.160 1 ms")!]
        restored.resolveGeography(); restored.reset()
        await settle(restored)
        assert(restored.geo.isEmpty)
        print("PASS: MMDB official fixture, 24/28/32-bit trees, country/province localization, pointer widths, size encodings, corrupt/resource-limited records, persistence, gzip, failed replacement, override priority, immutable replay, reset isolation")
    }
    static func check(_ condition: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) rethrows {
        let result = try condition(); assert(result, file: file, line: line)
    }
    @MainActor static func settle(_ store: RouteStore) async {
        let deadline = Date().addingTimeInterval(3)
        while store.geoLoading && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    static var city: [UInt8] {
        map([("country", map([("names", map([("zh-CN", string("中国"))]))])),
             ("subdivisions", [1, 4] + map([("names", map([("zh-CN", string("上海"))]))]))])
    }
    static func string(_ text: String) -> [UInt8] { header(2, text.utf8.count) + Array(text.utf8) }
    static func map(_ pairs: [(String, [UInt8])]) -> [UInt8] { header(7, pairs.count) + pairs.flatMap { string($0.0) + $0.1 } }
    static func header(_ type: UInt8, _ size: Int) -> [UInt8] {
        if size < 29 { return [type << 5 | UInt8(size)] }
        if size < 285 { return [type << 5 | 29, UInt8(size - 29)] }
        if size < 65821 { let n = size - 285; return [type << 5 | 30, UInt8(n >> 8), UInt8(n & 255)] }
        let n = size - 65821; return [type << 5 | 31, UInt8(n >> 16), UInt8((n >> 8) & 255), UInt8(n & 255)]
    }
    static func uint(_ value: Int) -> [UInt8] { [0xc4] + (0..<4).reversed().map { UInt8((value >> ($0 * 8)) & 255) } }
    static func database(recordSize: Int = 24, record: [UInt8]) -> Data {
        let left = 17; let right = 1
        var tree: [UInt8]
        if recordSize == 28 { tree = [0, 0, UInt8(left), 0, 0, 0, UInt8(right)] }
        else {
            let count = recordSize / 8
            tree = [left, right].flatMap { n in (0..<count).reversed().map { UInt8((n >> ($0 * 8)) & 255) } }
        }
        let meta = map([("node_count", uint(1)), ("record_size", uint(recordSize)), ("ip_version", uint(4)),
                        ("binary_format_major_version", uint(2)), ("database_type", string("DBIP-City-Lite")), ("build_epoch", uint(1700000000))])
        return Data(tree + Array(repeating: 0, count: 16) + record + [0xab, 0xcd, 0xef] + Array("MaxMind.com".utf8) + meta)
    }
}
