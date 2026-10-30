import SwiftUI
import AppKit

extension Notification.Name {
    static let netPulseNewSession = Notification.Name("netPulseNewSession")
    static let netPulseRouteTarget = Notification.Name("netPulseRouteTarget")
}
struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var s: Store
    @EnvironmentObject var route: RouteStore
    @EnvironmentObject var speed: SpeedStore
    @EnvironmentObject var workspaces: Workspaces
    @State private var newKind = WorkspaceKind.quality
    @State private var replaceTarget = ""
    @State private var showReplace = false
    @State private var showNew = false
    private let navigationBlue = Color(red: 0.12, green: 0.49, blue: 0.78)
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                HStack {
                    AppLogo()
                    VStack(alignment: .leading) {
                        Text("NetPulse").font(.title.bold())
                        Text("网络质量，看得见，也留得住").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("监测 · 诊断 · 测速 · 本机").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 14)
            HStack(spacing: 5) {
                workspaceButton(0, title: "质量监测", detail: "Ping · 丢包 / 往返时延 / 抖动", icon: "waveform.path.ecg", running: s.running)
                workspaceButton(1, title: "路径诊断", detail: "Traceroute · 逐跳路径与回复", icon: "point.3.connected.trianglepath.dotted", running: route.running)
                workspaceButton(3, title: "网络测速", detail: "吞吐量 · 空闲与负载时延", icon: "speedometer", running: speed.running)
                workspaceButton(2, title: "本机网络", detail: "地址 · 出口 · Wi-Fi 信号", icon: "wifi", running: false)
            }.padding(5)
                .background(navigationBlue.opacity(colorScheme == .dark ? 0.10 : 0.07), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(navigationBlue.opacity(0.15)))
                .padding(.horizontal, 26).padding(.bottom, 8)
            Group {
                if workspaces.page == 0 { PingView() }
                else if workspaces.page == 1 { RouteView() }
                else if workspaces.page == 2 { LocalNetworkView().environmentObject(workspaces.local) }
                else { SpeedView() }
            }.disabled(workspaces.resetting.contains(WorkspaceKind(rawValue: workspaces.page) ?? .quality))
        }.background(alignment: .bottomTrailing) { SpeedWebHost(engine: speed.webEngine).frame(width: 4, height: 4).allowsHitTesting(false).accessibilityHidden(true) }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .netPulseNewSession)) { event in
            let kind = (event.object as? Int).flatMap(WorkspaceKind.init(rawValue:)) ?? WorkspaceKind(rawValue: workspaces.page) ?? .quality
            if kind == .speed { Task { await workspaces.reset(.speed) }; return }
            if kind == .local { workspaces.local.refresh(); return }
            if !workspaces.resetting.contains(kind) { newKind = kind; showNew = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .netPulseRouteTarget)) { event in
            guard let target = event.object as? String else { return }
            if workspaces.needsRouteReplacement(target) { replaceTarget = target; showReplace = true }
            else { Task { await workspaces.sendToRoute(target) } }
        }
        .alert(newKind == .quality ? "新建质量监测测试？" : "新建路径诊断测试？", isPresented: $showNew) {
            Button("取消", role: .cancel) {}
            Button("结束并新建") { let kind = newKind; Task { await workspaces.reset(kind) } }
        } message: { Text("只结束并清空当前工作区，另一个工作区继续运行，已有日志保留。") }
        .alert("替换路径诊断目标？", isPresented: $showReplace) {
            Button("取消", role: .cancel) {}
            Button("替换并切换") { let target = replaceTarget; Task { await workspaces.sendToRoute(target, replace: true) } }
        } message: { Text("路径诊断已有目标或结果。将保存并结束该测试，把目标改为 \(replaceTarget)，不会自动开始扫描，也不会影响质量监测。") }
    }
    func workspaceButton(_ id: Int, title: String, detail: String, icon: String, running: Bool) -> some View {
        let selected = workspaces.page == id
        return Button { workspaces.page = id } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 22, weight: .medium)).frame(width: 30)
                    .foregroundStyle(selected ? navigationBlue : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 17, weight: .semibold))
                        if running {
                            Text(id == 0 ? "采集中" : id == 3 ? "测速中" : "扫描中").font(.caption.weight(.medium)).foregroundStyle(.green)
                                .padding(.horizontal, 7).padding(.vertical, 3).background(Color.green.opacity(0.09), in: Capsule())
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 4)
            }.foregroundStyle(selected ? navigationBlue : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(navigationBlue.opacity(colorScheme == .dark ? 0.28 : 0.17))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(navigationBlue.opacity(0.40), lineWidth: 1.2))
                            .shadow(color: navigationBlue.opacity(0.16), radius: 4, x: 0, y: 2)
                    }
                }
                .overlay(alignment: .bottom) {
                    if selected { Capsule().fill(navigationBlue.opacity(0.8)).frame(width: 30, height: 3).padding(.bottom, 4) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).animation(.easeInOut(duration: 0.15), value: selected).accessibilityLabel(title)
            .accessibilityValue("\(selected ? "当前工作区" : "切换工作区")\(running ? "，正在采集" : "")")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
