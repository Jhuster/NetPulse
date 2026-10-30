import Foundation
import AppKit

@main struct SpeedWebSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("assets/speedtest")
        let engine = SpeedWebEngine(resourceURL: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 4, height: 4), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = engine.webView
        var done = false
        let cancel = CommandLine.arguments.contains("--cancel")
        var stopping = false
        func end(_ code: Int32, _ message: String) { guard !done else { return }; done = true; print(message); engine.destroy(); fflush(stdout); Darwin.exit(code) }
        engine.onFailure = { end(1, "FAIL: WebKit \($0)") }
        engine.onMessage = { message in
            let event = message["event"] as? String ?? ""
            if cancel && event == "update" && !stopping {
                stopping = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    engine.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        guard engine.webView.url?.absoluteString == "about:blank" else { end(1, "FAIL: native stop did not tear down page"); return }
                        end(0, "PASS: native stop tears down WebKit page during active measurement")
                    }
                }
            }
            if stopping { return }
            if event == "error" { end(1, "FAIL: \(message["message"] ?? "unknown")") }
            if event == "finish" {
                let summary = message["summary"] as? [String: Any] ?? [:]
                guard summary["download"] is NSNumber, summary["upload"] is NSNumber, summary["latency"] is NSNumber else { end(1, "FAIL: incomplete WebKit summary \(summary)"); return }
                end(0, "PASS: WebKit Cloudflare latency/download/upload, small payload; scheduled=\(message["scheduledBytes"] ?? "unknown") bytes")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { end(1, "FAIL: WebKit smoke timeout") }
        engine.start(["session": UUID().uuidString, "budget": 600_000, "measurements": [["type": "latency", "numPackets": 6], ["type": "download", "bytes": 128_000, "count": 2, "bypassMinDuration": true], ["type": "upload", "bytes": 128_000, "count": 2, "bypassMinDuration": true]]])
        app.run()
    }
}
