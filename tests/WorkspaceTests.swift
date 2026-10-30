import Foundation

@main struct WorkspaceTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:"/private/tmp/NetPulse-workspace-test-\(UUID().uuidString)")
        let defaults = Workspaces()
        assert(defaults.ping.target == "1.1.1.1" && defaults.route.target == "1.1.1.1")
        assert(!defaults.ping.running && !defaults.route.running)
        defaults.route.target = "8.8.8.8"
        assert(defaults.ping.target == "1.1.1.1")
        let ping = Store(); ping.logRoot = root; ping.target = "127.0.0.1"
        // A long-lived harmless process verifies scope boundaries without public probes.
        let route = RouteStore(executableURL:URL(fileURLWithPath:"/bin/sleep"),arguments:["30"])
        route.logRoot = root; route.target = "192.0.2.2"
        let workspace = Workspaces(ping:ping,route:route)
        ping.begin(); route.begin(route.target)
        try await Task.sleep(nanoseconds:1_000_000_000)
        assert(ping.running && route.running && ping.target != route.target)
        workspace.page = WorkspaceKind.local.rawValue
        assert(!workspace.importFile(URL(fileURLWithPath: "/invalid"), into: .local))
        await workspace.reset(.local)
        assert(ping.running && route.running && workspace.local.exitInfo == nil)
        workspace.local.stop()
        let routeLog = route.logURL
        await workspace.reset(.quality)
        assert(!ping.running && ping.logURL == nil && route.running && route.logURL == routeLog && route.target == "192.0.2.2")
        ping.begin()
        try await Task.sleep(nanoseconds:500_000_000)
        await workspace.reset(.route)
        assert(ping.running && !route.running && !route.hasSession && ping.target == "127.0.0.1")
        let pingLog = ping.logURL!
        let demo = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("docs/examples/route-demo.csv")
        assert(workspace.importFile(demo,into:.route))
        assert(route.imported && route.target == "example.net" && ping.running && ping.logURL == pingLog && ping.target == "127.0.0.1")
        let rejected = await workspace.sendToRoute(ping.target)
        assert(!rejected && route.target == "example.net" && route.imported && ping.running)
        let accepted = await workspace.sendToRoute(ping.target,replace:true)
        assert(accepted && route.target == ping.target && !route.hasSession && !route.running && workspace.page == 1 && ping.running)
        await workspace.reset(.quality)
        route.target = "198.51.100.23"; route.begin(route.target)
        let independentRouteLog = route.logURL
        assert(workspace.importFile(pingLog,into:.quality))
        assert(ping.imported && ping.target == "127.0.0.1" && route.running && route.target == "198.51.100.23" && route.logURL == independentRouteLog)
        assert(!workspace.importFile(demo,into:.quality))
        assert(route.running && route.logURL == independentRouteLog)
        workspace.page = 0; workspace.page = 1
        assert(route.running && ping.target != route.target)
        await workspace.reset(.route)
        assert(!route.running && route.process == nil && ping.imported)
        print("PASS: independent targets, per-workspace reset/import, background continuity, protected target handoff, no automatic scan; fixtures: \(root.path)")
    }
}
