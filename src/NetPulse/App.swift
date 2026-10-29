import SwiftUI
import Charts
import AppKit

func metric(_ value: Double?, unit: String = "") -> String {
    guard let value else { return "—" }
    return String(format: "%.2f", value) + unit
}
@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    weak var store: Store?
    weak var route: RouteStore?
    private var finishing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Explicitly refresh the running Dock tile from this bundle. An updated
        // ICNS alone can leave the old Launch Services icon visible in the Dock.
        if let icon = Branding.icon { NSApplication.shared.applicationIconImage = icon }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !finishing else { return .terminateLater }
        finishing = true
        Task { @MainActor in
            store.stop()
            await self.route?.stopAndWait()
            await store.finishForExit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { route?.reset(); store?.reset() }
}

@main struct NetPulseApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject var workspaces = Workspaces()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(workspaces).environmentObject(workspaces.ping).environmentObject(workspaces.route)
                .frame(minWidth: 960, minHeight: 780)
                .onAppear { lifecycle.store = workspaces.ping; lifecycle.route = workspaces.route }
        }.defaultSize(width: 1140, height: 900)
        .commands { CommandGroup(replacing: .newItem) { Button("新建测试") { NotificationCenter.default.post(name: .netPulseNewSession, object: nil) }.keyboardShortcut("n") } }
    }
}
struct PingView: View {
    @EnvironmentObject var s: Store
    @EnvironmentObject var workspaces: Workspaces
    @State var showRaw = false
    let accent = Color(red: 0.15, green: 0.45, blue: 0.95)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TargetInput(target: $s.target, title: "质量监测", locked: s.logURL != nil || s.running) {
                    NotificationCenter.default.post(name: .netPulseNewSession, object: WorkspaceKind.quality.rawValue)
                }
                HStack {
                    Label(s.imported ? "离线回放" : s.running ? "正在采集" : "准备就绪 / 已暂停", systemImage: s.running ? "record.circle" : "pause.circle")
                        .foregroundStyle(s.running ? Color.green : .secondary)
                    Spacer()
                    Button("导入日志", systemImage: "square.and.arrow.down") { workspaces.pickImport(.quality) }.disabled(s.running)
                    Button("新建测试", systemImage: "plus") { NotificationCenter.default.post(name: .netPulseNewSession, object: WorkspaceKind.quality.rawValue) }
                    Button("对该目标做路径诊断", systemImage: "point.3.connected.trianglepath.dotted") {
                        NotificationCenter.default.post(name: .netPulseRouteTarget, object: s.target)
                    }.disabled(s.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { s.running ? s.stop() : s.begin() } label: {
                        Label(s.running ? "暂停探测" : s.logURL == nil ? "开始探测" : "继续探测", systemImage: s.running ? "pause.fill" : "play.fill")
                    }.buttonStyle(.borderedProminent).disabled(s.imported)
                }
                HStack(spacing: 12) {
                    stat(s.follow ? "最近 60 秒 Ping 丢包率" : "浏览位置前 60 秒丢包率", metric(s.recentLoss.percent, unit: "%"), s.recentLossDetail, .pink)
                    stat("平均往返时延（RTT）", metric(s.focused?.avg, unit: " ms"), "所选 5 秒窗口", accent)
                    stat("Jitter", metric(s.focused?.jitter, unit: " ms"), "RTT 相邻差 · 丢包断开", .orange)
                    stat("成功 / 完成 / 错误", "\(s.received) / \(s.sent) / \(s.errors)", "实际 IP：\(s.resolved)", .teal)
                }
                HStack(spacing: 14) {
                    Text("会话概览").font(.subheadline.weight(.semibold))
                    Text("累计 Ping 丢包率：\(metric(s.totalLoss, unit: "%"))")
                    Spacer()
                    Text("近期丢包率按已完成的 5 秒窗口汇总；错误不计入分母")
                }.font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 14) {
                    HStack {
                        Text("质量时间线").font(.headline)
                        Spacer()
                        Picker("时间范围", selection: $s.span) { Text("1 分钟").tag(60.0); Text("5 分钟").tag(300.0); Text("30 分钟").tag(1800.0); Text("2 小时").tag(7200.0) }.frame(width: 175)
                        Button("上一处丢包") { s.jump(-1) }
                        Button("下一处") { s.jump(1) }
                        Button(s.follow ? "暂停跟随" : "回到实时") { s.follow.toggle(); if s.follow { s.selectedDate = nil; s.endDate = Date() } }.disabled(s.imported)
                    }
                    if s.samples.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "chart.xyaxis.line").font(.system(size: 40)).foregroundStyle(accent.opacity(0.6))
                            Text("从一次 Ping 开始").font(.title3.bold())
                            Text("实时观察丢包与时延，自动保存日志，随时暂停查看历史。当前窗口会在回复或超时后逐步更新。")
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        timeline("Ping 丢包率", unit: "%", color: .pink, key: \.loss)
                        timeline("平均往返时延（RTT）", unit: "ms", color: accent, key: \.avg)
                        timeline("Jitter · RTT 相邻差", unit: "ms", color: .orange, key: \.jitter)
                        HStack {
                            Text("浏览历史").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { s.endDate.timeIntervalSince1970 }, set: { s.follow = false; s.endDate = Date(timeIntervalSince1970: $0) }), in: historyRange)
                            Text(s.endDate, format: .dateTime.hour().minute().second()).monospacedDigit()
                        }
                    }
                    Text("5 秒窗口 · 曲线不跨缺失区间连接 · 悬停联动查看；末尾窗口可能尚未完成").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
                HStack(alignment: .top) {
                    Image(systemName: "info.circle").foregroundStyle(accent)
                    Text(s.notice).textSelection(.enabled)
                    Spacer()
                }.font(.callout)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("日志自动保存").font(.headline)
                        Text(s.logURL?.path ?? "开始探测后自动创建本地 CSV 日志").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("在 Finder 中显示", systemImage: "folder") { s.reveal() }.disabled(s.logURL == nil)
                    Button("导出日志", systemImage: "square.and.arrow.up") { s.export() }.disabled(s.logURL == nil)
                }
                DisclosureGroup("所选窗口与原始记录", isExpanded: $showRaw) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let w = s.focused {
                            Text("\(w.date.formatted()) · \(w.sent) 条完成记录 · min \(metric(w.minimum)) / max \(metric(w.maximum)) ms")
                            if w.summary != nil { Text("CSV 保存窗口统计；逐包原始输出请查看会话目录中的 diagnostics.txt。").foregroundStyle(.secondary) }
                            ForEach(w.probes.sorted { $0.id < $1.id }) { p in
                                Text("#\(p.id)  \(p.status)  \(p.sentAt.formatted())\n\(p.raw)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        } else { Text("暂无记录").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }
                Text("ICMP 探测反映 Ping 的可达性和往返时延，业务连接质量需结合实际业务判断。NetPulse 0.1 · Preview")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }.background(Color(nsColor: .windowBackgroundColor))

    }
    var historyRange: ClosedRange<Double> {
        let first = s.samples.first?.date.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let last = max(first+1, s.samples.last?.date.addingTimeInterval(5).timeIntervalSince1970 ?? first+1)
        return min(first, s.endDate.timeIntervalSince1970)...max(last, s.endDate.timeIntervalSince1970)
    }
    func stat(_ title: String, _ value: String, _ subtitle: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
    func timeline(_ title: String, unit: String, color: Color, key: KeyPath<WindowSample, Double?>) -> some View {
        let rows = s.visible
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title).font(.subheadline.weight(.medium)); Spacer(); Text(metric(s.focused?[keyPath: key], unit: " \(unit)")).foregroundStyle(color).monospacedDigit() }
            Chart {
                ForEach(rows) { w in
                    if let value = w[keyPath: key] {
                        PointMark(x: .value("时间", w.date), y: .value(title, value)).foregroundStyle(color).symbolSize(12)
                        // 每个相邻窗口单独一段，缺失窗口不连线。
                        if let next = byID[w.id+1], let y = next[keyPath: key] {
                            LineMark(x: .value("时间", w.date), y: .value(title, value), series: .value("段", w.id)).foregroundStyle(color)
                            LineMark(x: .value("时间", next.date), y: .value(title, y), series: .value("段", w.id)).foregroundStyle(color)
                        }
                    }
                }
                if let date = s.selectedDate { RuleMark(x: .value("所选时间", date)).foregroundStyle(.secondary.opacity(0.4)) }
            }.chartXScale(domain: s.domain)
                .chartYScale(domain: 0...yMax(key))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second()) } }
                .chartOverlay { proxy in GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                        if case .active(let point) = phase, let frame = proxy.plotFrame {
                            let x = point.x-geo[frame].origin.x
                            if let date: Date = proxy.value(atX: x) { s.selectedDate = date }
                        }
                    }
                } }.frame(height: 108)
        }
    }
    func yMax(_ key: KeyPath<WindowSample, Double?>) -> Double { key == \WindowSample.loss ? 100 : max(1, (s.visible.compactMap { $0[keyPath: key] }.max() ?? 1)*1.15) }
}
