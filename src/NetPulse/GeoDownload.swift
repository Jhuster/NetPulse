import Foundation

enum GeoDownloadError: LocalizedError {
    case badPage, response, tooLarge, insecureRedirect
    var errorDescription: String? {
        switch self {
        case .badPage: return "未能从官方页面找到最新 MMDB 下载地址，请稍后重试或导入文件"
        case .response: return "下载服务返回异常，请稍后重试"
        case .tooLarge: return "下载文件超过 512 MB 上限"
        case .insecureRedirect: return "下载重定向到非官方或非 HTTPS 地址，已停止"
        }
    }
}

// Only obtains a public database archive from DB-IP. Route addresses are never
// included in a request. The official page determines the release, not the clock.
final class GeoDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let page = URL(string: "https://db-ip.com/db/download/ip-to-city-lite")!
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var cancelled = false
    private var failure: Error?
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination; self.progress = progress
    }
    static func archiveURL(in html: String) throws -> URL {
        guard html.utf8.count <= 2_000_000 else { throw GeoDownloadError.badPage }
        let pattern = #"https://download\.db-ip\.com/free/dbip-city-lite-[0-9]{4}-[0-9]{2}\.mmdb\.gz"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        let urls = matches.compactMap { Range($0.range, in: html).map { String(html[$0]) } }
        guard let newest = urls.sorted().last, let url = URL(string: newest) else { throw GeoDownloadError.badPage }
        return url
    }
    static func latestArchiveURL() async throws -> URL {
        var request = URLRequest(url: page); request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", ["db-ip.com", "www.db-ip.com"].contains(response.url?.host ?? ""),
              let html = String(data: data, encoding: .utf8) else { throw GeoDownloadError.response }
        return try archiveURL(in: html)
    }
    func download(_ url: URL) async throws -> URL {
        guard url.scheme == "https", url.host == "download.db-ip.com" else { throw GeoDownloadError.insecureRedirect }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                lock.lock()
                self.session = session; self.task = task; self.continuation = continuation
                let wasCancelled = cancelled
                lock.unlock()
                if wasCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let session = session; self.session = nil; task = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 512 * 1024 * 1024 || totalBytesExpectedToWrite > 512 * 1024 * 1024 {
            failure = GeoDownloadError.tooLarge; downloadTask.cancel(); return
        }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https", response.url?.host == "download.db-ip.com" else { throw GeoDownloadError.response }
            guard (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512 * 1024 * 1024 else { throw GeoDownloadError.tooLarge }
            try FileManager.default.moveItem(at: location, to: destination)
            complete(.success(destination))
        } catch { complete(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(failure ?? error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == "download.db-ip.com" else {
            failure = GeoDownloadError.insecureRedirect; completionHandler(nil); return
        }
        completionHandler(request)
    }
}
