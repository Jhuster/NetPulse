import SwiftUI
import Charts

struct RouteView: View {
    @EnvironmentObject var workspaces: Workspaces
    @EnvironmentObject var route: RouteStore
    @State private var rawExpanded = false
    @State private var geoSettings = false
    func color(_ hop: RouteHop) -> Color {
        if hop.probes.contains(where: { !$0.annotation.isEmpty }) { return .red }
        if hop.received == 0 { return .secondary }
        if hop.received < hop.probes.count || hop.addresses.count > 1 { return .orange }
        return .green
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TargetInput(target: $route.target, title: "路径诊断", locked: route.hasSession || route.running) {
                    NotificationCenter.default.post(name: .netPulseNewSession, object: WorkspaceKind.route.rawValue)
                }
                HStack {
                    Text("快速查看路径").font(.headline)
                    Text("Traceroute · ICMP").font(.caption).foregroundStyle(.secondary)
                    Button("持续观察（MTR，后续支持）") {}.disabled(true)
                    Spacer()
                    Button("导入日志", systemImage: "square.and.arrow.down") { workspaces.pickImport(.route) }.disabled(route.running)
                    Button("新建测试", systemImage: "plus") { NotificationCenter.default.post(name: .netPulseNewSession, object: WorkspaceKind.route.rawValue) }
                    Button {
                        if route.running { route.halt() } else { route.begin(route.target) }
                    } label: { Label(route.running ? "停止扫描" : route.hasSession ? "重新扫描" : "开始扫描", systemImage: route.running ? "stop.fill" : "play.fill") }
                        .buttonStyle(.borderedProminent)
                }
                HStack(alignment: .top, spacing: 20) {
                    summary("测试结果", route.imported ? "离线回放 · \(route.statusTitle)" : route.statusTitle, "已观察 \(route.hops.count) 个 TTL")
                    summary("实际目标 IP", route.targetIP.isEmpty ? "等待解析" : route.targetIP, "协议 ICMP · 每跳最多 3 个样本")
                    summary("出口网关 / 接口", route.gateway.isEmpty ? "未识别 / 直连或无可见网关" : route.gateway, route.networkInterface.isEmpty ? "按目标实际路由识别" : route.networkInterface)
                }
                Label(route.message, systemImage: "info.circle").font(.callout).textSelection(.enabled)
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "globe.asia.australia.fill").font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.imported ? "IP 地理归属 · 日志快照" : "IP 地理归属 · 离线查询").font(.subheadline.bold())
                        Text(route.geoSource).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if !route.imported && route.geoDatabase == nil {
                            Text("DB-IP City Lite · 约百 MB · CC BY 4.0；安装后离线查询")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if route.geoSource.lowercased().contains("dbip") || route.geoSource.lowercased().contains("db-ip") {
                            Link("IP Geolocation by DB-IP · CC BY 4.0", destination: URL(string: "https://db-ip.com")!).font(.caption2)
                        } else if route.geoSource.lowercased().contains("geoip") || route.geoSource.lowercased().contains("geolite") {
                            Link("GeoIP 数据由 MaxMind 提供", destination: URL(string: "https://www.maxmind.com")!).font(.caption2)
                        }
                    }
                    Spacer()
                    if route.geoLoading {
                        ProgressView().controlSize(.small)
                        if route.geoDownloading { Button("取消") { route.cancelGeoDownload() } }
                    } else if route.geoDatabase == nil && !route.imported {
                        Button("下载并启用", systemImage: "arrow.down.circle") { route.downloadGeoDatabase() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    Button(route.geoDatabase == nil ? "设置" : "管理归属数据库", systemImage: "globe") { geoSettings = true }
                        .buttonStyle(.bordered).controlSize(.large)
                }.padding(14).background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                if route.geoLoading || route.geoDatabase == nil {
                    HStack {
                        Text(route.geoMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if route.geoDownloading, let progress = route.geoDownloadProgress { ProgressView(value: progress).frame(width: 140) }
                    }
                }
                if route.hops.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 36)).foregroundStyle(.blue)
                        Text(route.running ? "正在等待系统逐跳结果" : "看看到目标的路径").font(.title3.bold())
                        Text("逐跳展示节点、往返时延与回复状态。中间不回复，不等于转发丢包。")
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    hopTable
                    if let hop = route.selected { selectedDetail(hop) }
                }
                HStack {
                    Label("收到回复", systemImage: "circle.fill").foregroundStyle(.green)
                    Label("异常响应", systemImage: "circle.fill").foregroundStyle(.red)
                    Label("需关注", systemImage: "circle.fill").foregroundStyle(.orange)
                    Label("未知 / 未回复", systemImage: "circle.fill").foregroundStyle(.secondary)
                    Spacer()
                }.font(.caption)
                Text("国家/省份为 IP 地理归属参考，不能代表节点的实测物理位置；缺失信息保留未知。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(route.logURL?.path ?? "开始扫描后自动保存独立路径日志").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("在 Finder 中显示", systemImage: "folder") { route.reveal() }.disabled(route.logURL == nil)
                    Button("导出路径", systemImage: "square.and.arrow.up") { route.export() }.disabled(route.logURL == nil)
                }
                DisclosureGroup("系统原始输出", isExpanded: $rawExpanded) {
                    Text(route.raw.isEmpty ? "导入后的原始输出请查看配套 route-diagnostics.txt。" : route.raw)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("这是一次路径快照；每跳 RTT 为本机到回复节点的往返时间，相邻行差值不代表链路时延。3 个样本不足以评价长期丢包率。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.sheet(isPresented: $geoSettings) { GeoSettingsView().environmentObject(route) }
    }
    var hopTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TTL").frame(width: 36, alignment: .leading)
                Text("节点 / 国家 · 省份").frame(maxWidth: .infinity, alignment: .leading)
                Text("回复 / 样本").frame(width: 85, alignment: .trailing)
                Text("平均 RTT").frame(width: 95, alignment: .trailing)
                Text("状态").frame(width: 155, alignment: .leading)
            }.font(.caption).foregroundStyle(.secondary).padding(12)
            Divider()
            ForEach(route.hops) { hop in
                Button { route.selectedHop = hop.id } label: {
                    HStack(alignment: .top) {
                        Text(String(hop.id)).frame(width: 36, alignment: .leading).monospacedDigit()
                        VStack(alignment: .leading, spacing: 6) {
                            if hop.addresses.isEmpty { Text("未识别节点").foregroundStyle(.secondary) }
                            ForEach(hop.addresses, id: \.self) { ip in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(ip).font(.system(.body, design: .monospaced))
                                        if ip == route.gateway { Text("出口网关").font(.caption).foregroundStyle(.blue) }
                                        if ip == route.targetIP { Text("目标").font(.caption).foregroundStyle(.blue) }
                                    }
                                    Text(route.geoText(ip)).font(.caption).foregroundStyle(.secondary)
                                        .help(route.geo[ip]?.source ?? "未找到地理归属记录")
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(hop.received) / \(hop.probes.count)").monospacedDigit().frame(width: 85, alignment: .trailing)
                        Text(metric(hop.avg, unit: " ms")).monospacedDigit().frame(width: 95, alignment: .trailing)
                        Label(hop.state, systemImage: "circle.fill").font(.caption).foregroundStyle(color(hop)).frame(width: 155, alignment: .leading)
                    }.padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain).background(route.selected?.id == hop.id ? Color.blue.opacity(0.08) : .clear)
                Divider()
            }
        }.background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
    func selectedDetail(_ hop: RouteHop) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("第 \(hop.id) 跳 · 单次扫描样本").font(.headline); Spacer(); Text("不是持续时序").font(.caption).foregroundStyle(.secondary) }
            Chart(hop.probes) { p in
                if let rtt = p.rtt {
                    PointMark(x: .value("样本序号", p.id+1), y: .value("RTT (ms)", rtt)).foregroundStyle(.blue)
                        .annotation(position: .top) { Text(metric(rtt)).font(.caption2) }
                }
            }.chartXScale(domain: 0.5...Double(max(3,hop.probes.count))+0.5).chartYScale(domain: 0...max(1,(hop.probes.compactMap(\.rtt).max() ?? 1)*1.3))
                .chartXAxis { AxisMarks(values: hop.probes.map { $0.id+1 }) }.chartYAxisLabel("RTT (ms)")
                .frame(height: 130)
            Text(hop.raw).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            ForEach(hop.addresses, id: \.self) { ip in
                if let location = route.geo[ip] {
                    Text("\(ip) · \(route.geoText(ip)) · 来源：\(location.source)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if hop.received == 0 { Text("本跳没有回复，但不表示路径在此中断；请结合后续跳和目标结果。") .font(.caption).foregroundStyle(.secondary) }
            if !route.gateway.isEmpty && hop.addresses.contains(route.gateway) { Text(route.imported ? "网关标签来自日志记录的网关信息。" : "网关标签来自本机对目标 IP 的路由查询。").font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
    func summary(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).textSelection(.enabled)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}
