import Foundation

enum GeoDatabaseError: LocalizedError {
    case invalid, unsupported, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: return "数据库损坏或不是有效的 MMDB 文件"
        case .unsupported: return "请选择 DB-IP City Lite 或 GeoIP / GeoLite City、Country 的 MMDB 数据库"
        case .tooLarge: return "数据库超过 512 MB 上限"
        }
    }
}

// A bounded reader for MMDB v2. No external library or network lookup is needed.
// Format: https://maxmind.github.io/MaxMind-DB/
struct GeoDatabase: Sendable {
    private let data: Data
    private let nodes: Int
    private let recordSize: Int
    private let treeSize: Int
    private let metadataOffset: Int
    private let ipVersion: Int
    let databaseType: String
    let buildDate: String
    var source: String { "\(databaseType) · \(buildDate)" }
    var attribution: String {
        databaseType.lowercased().contains("dbip") || databaseType.lowercased().contains("db-ip")
            ? "IP Geolocation by DB-IP · CC BY 4.0" : "GeoIP 数据由 MaxMind 提供"
    }
    var attributionURL: URL {
        URL(string: databaseType.lowercased().contains("dbip") || databaseType.lowercased().contains("db-ip") ? "https://db-ip.com" : "https://www.maxmind.com")!
    }
    init(url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 512 * 1024 * 1024 else { throw GeoDatabaseError.tooLarge }
        // Own the bytes: replacing an installed file cannot invalidate an active lookup.
        try self.init(data: Data(contentsOf: url))
    }
    init(data: Data) throws {
        guard data.count <= 512 * 1024 * 1024 else { throw GeoDatabaseError.tooLarge }
        let marker = Data([0xab, 0xcd, 0xef] + Array("MaxMind.com".utf8))
        guard let range = data.range(of: marker, options: .backwards, in: max(0, data.count - 131072)..<data.count) else { throw GeoDatabaseError.invalid }
        var decoder = MMDBDecoder(data: data, base: range.upperBound, end: data.count)
        var cursor = range.upperBound
        guard case let .map(meta) = try decoder.decode(&cursor),
              let nodes = meta["node_count"]?.integer, nodes > 0,
              let recordSize = meta["record_size"]?.integer, [24, 28, 32].contains(recordSize),
              let ipVersion = meta["ip_version"]?.integer, [4, 6].contains(ipVersion),
              meta["binary_format_major_version"]?.integer == 2,
              let kind = meta["database_type"]?.string, kind.count <= 100,
              let epoch = meta["build_epoch"]?.integer, epoch > 0, epoch <= 253402300799 else { throw GeoDatabaseError.invalid }
        let lower = kind.lowercased()
        guard (lower.contains("city") || lower.contains("country")),
              lower.contains("dbip") || lower.contains("db-ip") || lower.contains("geoip") || lower.contains("geolite") else { throw GeoDatabaseError.unsupported }
        let treeSize = nodes * (recordSize / 4)
        guard treeSize + 16 <= range.lowerBound,
              data[treeSize..<(treeSize + 16)].allSatisfy({ $0 == 0 }) else { throw GeoDatabaseError.invalid }
        self.data = data; self.nodes = nodes; self.recordSize = recordSize
        self.treeSize = treeSize; self.ipVersion = ipVersion; metadataOffset = range.lowerBound
        databaseType = kind.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "yyyy-MM-dd"
        buildDate = format.string(from: Date(timeIntervalSince1970: Double(epoch)))
    }
    func lookup(_ ip: String) throws -> GeoLocation? {
        guard geographicAddress(ip) else { return nil }
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        let bits = (ipVersion == 6 ? Array(repeating: 0, count: 96) : []) + octets.flatMap { octet in (0..<8).reversed().map { Int((octet >> $0) & 1) } }
        var node = 0
        for bit in bits {
            if node >= nodes { break }
            let offset = node * (recordSize / 4)
            if recordSize == 28 {
                let high = Int(data[offset + 3])
                node = (bit == 0 ? high >> 4 : high & 15) << 24
                node |= number(at: offset + (bit == 0 ? 0 : 4), count: 3)
            } else { node = number(at: offset + bit * (recordSize / 8), count: recordSize / 8) }
        }
        if node == nodes { return nil }
        guard node >= nodes + 16 else { throw GeoDatabaseError.invalid }
        var cursor = treeSize + node - nodes
        var decoder = MMDBDecoder(data: data, base: treeSize + 16, end: metadataOffset)
        guard case let .map(record) = try decoder.decode(&cursor) else { throw GeoDatabaseError.invalid }
        let country = record["country"]?.map ?? [:]
        var countryName = name(country)
        if countryName.isEmpty, let code = country["iso_code"]?.string {
            countryName = Locale(identifier: "zh_CN").localizedString(forRegionCode: code) ?? code
        }
        let subdivisions = record["subdivisions"]?.array ?? []
        // First subdivision is the state/province; do not substitute a city for it.
        let province = subdivisions.first?.map.map(name) ?? ""
        guard !countryName.isEmpty || !province.isEmpty else { return nil }
        return GeoLocation(country: countryName, province: province, source: source)
    }
    private func name(_ record: [String: MMDBValue]) -> String {
        let names = record["names"]?.map ?? [:]
        return names["zh-CN"]?.string ?? names["zh"]?.string ?? names["en"]?.string ?? ""
    }
    private func number(at offset: Int, count: Int) -> Int {
        data[offset..<(offset + count)].reduce(0) { ($0 << 8) | Int($1) }
    }
}

// Private/shared, documentation, benchmark, unspecified and multicast/reserved
// ranges have no meaningful public geographic attribution.
func geographicAddress(_ ip: String) -> Bool {
    guard validIPv4(ip), !nonPublicAddress(ip) else { return false }
    let p = ip.split(separator: ".").compactMap { Int($0) }
    return p[0] != 0 && p[0] < 224 && !(p[0] == 192 && p[1] == 0 && (p[2] == 0 || p[2] == 2))
        && !(p[0] == 198 && (p[1] == 18 || p[1] == 19 || (p[1] == 51 && p[2] == 100)))
        && !(p[0] == 203 && p[1] == 0 && p[2] == 113)
}

private indirect enum MMDBValue {
    case string(String), integer(Int), map([String: MMDBValue]), array([MMDBValue]), other
    var string: String? { if case let .string(v) = self { return v }; return nil }
    var integer: Int? { if case let .integer(v) = self { return v }; return nil }
    var map: [String: MMDBValue]? { if case let .map(v) = self { return v }; return nil }
    var array: [MMDBValue]? { if case let .array(v) = self { return v }; return nil }
}

private struct MMDBDecoder {
    let data: Data
    let base: Int
    let end: Int
    private var values = 0
    private var payload = 0
    init(data: Data, base: Int, end: Int) { self.data = data; self.base = base; self.end = end }
    mutating func decode(_ offset: inout Int, depth: Int = 0) throws -> MMDBValue {
        values += 1
        guard depth < 64, values <= 8192 else { throw GeoDatabaseError.invalid }
        let control = try read(&offset, count: 1)
        var type = control >> 5
        if type == 0 { type = try read(&offset, count: 1) + 7 }
        if type == 1 {
            let size = (control >> 3) & 3
            let prefix = size == 3 ? 0 : (control & 7) << ((size + 1) * 8)
            let bias = [0, 2048, 526336, 0][size]
            var pointer = base + prefix + (try read(&offset, count: size + 1)) + bias
            return try decode(&pointer, depth: depth + 1)
        }
        var size = control & 31
        if size == 29 { size = 29 + (try read(&offset, count: 1)) }
        else if size == 30 { size = 285 + (try read(&offset, count: 2)) }
        else if size == 31 { size = 65821 + (try read(&offset, count: 3)) }
        if type == 7 || type == 11 {
            guard size <= 2048 else { throw GeoDatabaseError.invalid }
            if type == 11 {
                var result: [MMDBValue] = []
                for _ in 0..<size { result.append(try decode(&offset, depth: depth + 1)) }
                return .array(result)
            }
            var result: [String: MMDBValue] = [:]
            for _ in 0..<size {
                guard case let .string(key) = try decode(&offset, depth: depth + 1), result[key] == nil else { throw GeoDatabaseError.invalid }
                result[key] = try decode(&offset, depth: depth + 1)
            }
            return .map(result)
        }
        if type == 14 { guard size <= 1 else { throw GeoDatabaseError.invalid }; return .other }
        guard offset >= base, offset <= end, size <= end - offset else { throw GeoDatabaseError.invalid }
        payload += size
        guard payload <= 1_048_576 else { throw GeoDatabaseError.invalid }
        if type == 2 {
            guard let string = String(data: data[offset..<(offset + size)], encoding: .utf8) else { throw GeoDatabaseError.invalid }
            offset += size; return .string(string)
        }
        if [5, 6, 9].contains(type) {
            let maximum = type == 5 ? 2 : type == 6 ? 4 : 8
            guard size <= maximum, !(size == 8 && data[offset] >= 128) else { throw GeoDatabaseError.invalid }
            return .integer(try read(&offset, count: size))
        }
        guard (type == 3 && size == 8) || type == 4 || (type == 8 && size <= 4) || (type == 10 && size <= 16) || (type == 15 && size == 4) else { throw GeoDatabaseError.invalid }
        offset += size; return .other
    }
    private func read(_ offset: inout Int, count: Int) throws -> Int {
        guard offset >= base, offset <= end, count <= end - offset else { throw GeoDatabaseError.invalid }
        let result = data[offset..<(offset + count)].reduce(0) { ($0 << 8) | Int($1) }
        offset += count; return result
    }
}
