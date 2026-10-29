import Foundation

enum GeoDatabaseInstaller {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NetPulse/GeoIP", isDirectory: true)
    }
    static func databaseURL(in directory: URL) -> URL { directory.appendingPathComponent("geolocation.mmdb") }
    static func install(from url: URL, in directory: URL) throws -> GeoDatabase {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString).mmdb")
        defer { try? fm.removeItem(at: staging) }
        if url.pathExtension.lowercased() == "gz" { try decompress(url, to: staging) }
        else {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512 * 1024 * 1024 else { throw GeoDatabaseError.tooLarge }
            try fm.copyItem(at: url, to: staging)
        }
        let database = try GeoDatabase(url: staging)
        // Verify a few tree traversals before replacing a previously working database.
        for ip in ["1.1.1.1", "8.8.8.8", "223.5.5.5"] { _ = try database.lookup(ip) }
        let destination = databaseURL(in: directory)
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staging) }
        else { try fm.moveItem(at: staging, to: destination) }
        return database
    }
    private static func decompress(_ source: URL, to destination: URL) throws {
        guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512 * 1024 * 1024 else { throw GeoDatabaseError.tooLarge }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", source.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? pipe.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        var total = 0
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 262144), !chunk.isEmpty {
            total += chunk.count
            guard total <= 512 * 1024 * 1024 else { throw GeoDatabaseError.tooLarge }
            try output.write(contentsOf: chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GeoDatabaseError.invalid }
    }
}
