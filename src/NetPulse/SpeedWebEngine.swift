import Foundation
import WebKit
import SwiftUI

@MainActor final class SpeedWebEngine: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    var onMessage: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    private var config: [String: Any]?
    private let resourceURL: URL
    init(resourceURL: URL) {
        self.resourceURL = resourceURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 4, height: 4), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "speed")
        webView.navigationDelegate = self
    }
    func start(_ config: [String: Any]) {
        self.config = config
        let index = resourceURL.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: index.path) else { onFailure?("测速引擎资源缺失，请重新构建应用"); return }
        webView.loadFileURL(index, allowingReadAccessTo: resourceURL)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any], let event = value["event"] as? String else { return }
        if event == "ready", let config {
            guard let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) else { onFailure?("测速配置无效"); return }
            webView.evaluateJavaScript("window.netpulse.start(\(json))") { [weak self] _, error in
                if let error { self?.onFailure?(error.localizedDescription) }
            }
        } else { onMessage?(value) }
    }
    func stop() {
        config = nil
        webView.evaluateJavaScript("window.netpulse?.stop()") { [weak self] _, _ in self?.destroy() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.destroy() }
    }
    func destroy() {
        config = nil; onMessage = nil; onFailure = nil
        webView.stopLoading(); webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "speed")
        webView.loadHTMLString("", baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure?(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure?(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure?("WebKit 测量进程已结束") }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(url.isFileURL && url.standardizedFileURL.path.hasPrefix(resourceURL.standardizedFileURL.path + "/") || url.absoluteString == "about:blank" ? .allow : .cancel)
    }
}

struct SpeedWebHost: NSViewRepresentable {
    let engine: SpeedWebEngine?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        if let web = engine?.webView {
            if web.superview !== view { view.subviews.forEach { $0.removeFromSuperview() }; view.addSubview(web); web.frame = view.bounds }
        } else { view.subviews.forEach { $0.removeFromSuperview() } }
    }
}
