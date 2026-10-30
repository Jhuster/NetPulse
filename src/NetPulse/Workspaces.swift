import Foundation
import AppKit

enum WorkspaceKind: Int { case quality = 0, route = 1, local = 2, speed = 3 }

@MainActor final class Workspaces: ObservableObject {
    let ping: Store
    let route: RouteStore
    let local = LocalNetworkStore()
    let speed = SpeedStore()
    @Published var page = 0
    @Published var resetting: Set<WorkspaceKind> = []
    init() { ping = Store(); route = RouteStore(); connectSpeed() }
    init(ping: Store, route: RouteStore) { self.ping = ping; self.route = route; connectSpeed() }
    private func connectSpeed() {
        speed.canStart = { [weak self] in self?.local.scanBusy != true }
        local.measurementBusy = { [weak self] in self?.speed.running == true || self?.speed.stopping == true }
        speed.onActivity = { [weak self] active in
            guard let ping = self?.ping, ping.running else { return }
            ping.write(active ? "load_start" : "load_end", message: "网络测速会占用带宽，请结合负载解读 Ping")
        }
    }
    func reset(_ kind: WorkspaceKind) async {
        guard !resetting.contains(kind) else { return }
        resetting.insert(kind); defer { resetting.remove(kind) }
        switch kind {
        case .quality: await ping.finishForExit()
        case .route: await route.stopAndWait(); route.reset()
        case .local: local.refresh()
        case .speed: await speed.stopAndWait(); speed.reset()
        }
    }
    func needsRouteReplacement(_ target: String) -> Bool {
        route.running || route.hasSession || (!route.target.isEmpty && route.target != target)
    }
    @discardableResult func sendToRoute(_ target: String, replace: Bool = false) async -> Bool {
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !resetting.contains(.route) else { return false }
        if needsRouteReplacement(target) {
            guard replace else { return false }
            await reset(.route)
        }
        route.target = target; page = WorkspaceKind.route.rawValue
        // Copy the target only; a cross-workspace action never starts a probe.
        return true
    }
    @discardableResult func importFile(_ url: URL, into kind: WorkspaceKind) -> Bool {
        switch kind {
        case .quality:
            guard !ping.running && !resetting.contains(.quality) else { return false }
            ping.load(url: url)
            return ping.imported && (ping.notice.hasPrefix("CSV 回放") || ping.notice.hasPrefix("离线回放"))
        case .route:
            guard !route.running && !resetting.contains(.route) else { return false }
            return route.load(url)
        case .speed: return speed.load(url)
        case .local: return false
        }
    }
    func pickImport(_ kind: WorkspaceKind) {
        guard kind != .local else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = kind == .speed ? "导入测速会话目录，或目录中的 summary.csv" : kind == .quality ? "导入质量监测日志，只影响当前工作区" : "导入路径诊断日志，只影响当前工作区"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url, into: kind)
    }
}
