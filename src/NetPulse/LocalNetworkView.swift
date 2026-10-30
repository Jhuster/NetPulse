import SwiftUI
import Charts

struct LocalNetworkView: View {
    @EnvironmentObject var local: LocalNetworkStore
    @State private var showInterfaces = false
    private let accent = Color(red: 0.12, green: 0.49, blue: 0.78)
    private var value: LocalNetworkSnapshot { local.snapshot }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本机网络").font(.title2.bold())
                        Text("先看本机连接，再结合质量监测与路径诊断定位问题。").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if local.reading { ProgressView().controlSize(.small) }
                    Button(local.observing ? "暂停观察" : "继续观察", systemImage: local.observing ? "pause.fill" : "play.fill") { local.toggleObservation() }
                    Button("刷新", systemImage: "arrow.clockwise") { local.refresh() }.disabled(local.reading || local.scanBusy)
                    Button("导出快照", systemImage: "square.and.arrow.up") { local.export() }.disabled(local.reading)
                }
                HStack(alignment: .top, spacing: 12) {
                    overview("本机接入方式", value.path.kinds.isEmpty ? "等待识别" : value.path.kinds.joined(separator: " / "), value.path.status, "network", .blue)
                    overview("局域网 IPv4", value.lanAddresses.isEmpty ? "未获取" : value.lanAddresses.joined(separator: "\n"), "物理接口地址；IPv6 见接口详情", "desktopcomputer", .primary)
                    overview("系统默认网关", [value.gateway4, value.gateway6].filter { !$0.isEmpty }.joined(separator: "\n").nilIfEmpty ?? "未获取 / 直连", "默认接口：\(value.primaryInterface.nilIfEmpty ?? "未识别")", "point.3.connected.trianglepath.dotted", .primary)
                    overview("Wi-Fi 信号", value.wifi?.rssi.map { "\($0) dBm · \(SignalLevel.rssi($0).rawValue)" } ?? "不可用", wifiStatus, "wifi", signalColor(SignalLevel.rssi(value.wifi?.rssi)))
                }
                HStack {
                    Label(value.path.status, systemImage: value.path.available ? "checkmark.circle" : "questionmark.circle")
                        .foregroundStyle(value.path.available ? Color.green : .secondary)
                    if value.path.expensive { Label("系统标记为高成本网络", systemImage: "dollarsign.circle") }
                    if value.path.constrained { Label("低数据模式", systemImage: "leaf") }
                    Spacer()
                    Text("更新 \(value.date.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                }.font(.caption)
                if !value.issue.isEmpty { Label(value.issue, systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
                exitSection
                wifiSection
                WiFiNearbyView().environmentObject(local)
                configurationSection
                DisclosureGroup("网络接口详情（\(value.interfaces.count)）", isExpanded: $showInterfaces) {
                    VStack(spacing: 0) {
                        ForEach(value.interfaces) { item in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.id + (item.id == value.primaryInterface ? " · 默认接口" : "")).font(.subheadline.bold())
                                    Text("\(item.name) · \(item.kind)").font(.caption).foregroundStyle(.secondary)
                                }.frame(width: 235, alignment: .leading)
                                Text(item.addresses.isEmpty ? "无 IP 地址" : item.addresses.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.up ? "UP" : "DOWN").font(.caption).foregroundStyle(item.up ? .green : .secondary)
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }.padding(.top, 8)
                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
                Label(local.notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let changed = local.lastChange { Text("最近一次本机配置变化：\(changed.formatted())").font(.caption).foregroundStyle(.secondary) }
                Text("系统路径可用不代表已经验证互联网连通；Wi-Fi 强信号不保证低时延、低丢包。手机热点在 Mac 上通常仍显示为 Wi-Fi，无法由此读取手机的 4G/5G 制式或蜂窝信号。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.onAppear { local.enter() }.onDisappear { local.stop() }
    }
    private var wifiStatus: String {
        guard let wifi = value.wifi else { return "未检测到可读 Wi-Fi 接口" }
        if !wifi.power { return "Wi-Fi 已关闭" }
        if !wifi.connected { return "未连接，或系统未提供连接信息" }
        return "\(wifi.interface) · \(wifi.interface == value.primaryInterface ? "默认上网接口" : "Wi-Fi 接口，可能非默认路径")"
    }
    private var exitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("互联网出口", systemImage: "globe").font(.headline)
                Spacer()
                if local.queryingExit { ProgressView().controlSize(.small) }
                Button(local.exitInfo == nil ? "查询出口 IP 与运营商" : "重新查询", systemImage: "arrow.up.right.circle") { local.queryExit() }
                    .buttonStyle(.borderedProminent).disabled(local.queryingExit)
            }
            if let exit = local.exitInfo {
                HStack(alignment: .top, spacing: 24) {
                    detail("出口 IP", exit.ip)
                    detail("出口 ISP", exit.isp.nilIfEmpty ?? "未知")
                    detail("ASN / 网络组织", [exit.asn, exit.organization].filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty ?? "未知")
                }.opacity(local.exitStale ? 0.55 : 1)
                HStack {
                    if local.exitStale { Label("已过期，不能代表当前出口", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    Text("查询时间：\(exit.date.formatted())").foregroundStyle(.secondary)
                }.font(.caption)
            }
            Text(local.exitMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Link("数据来源 IP.SB ↗", destination: URL(string: "https://ip.sb/api/")!).font(.caption)
                Text("仅按点击查询，不定时上传或更新。").font(.caption).foregroundStyle(.secondary)
            }
            Text("这里显示该 HTTPS 请求观察到的出口及网络归属，可能是 VPN / 代理的出口；它不一定等于宽带签约运营商，也不保证与某次 Ping 使用同一出口。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
    private var wifiSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Wi-Fi 连接与信号", systemImage: "wifi").font(.headline); Spacer(); Text(wifiStatus).font(.caption).foregroundStyle(.secondary) }
            if let wifi = value.wifi {
                HStack(alignment: .top, spacing: 24) {
                    detail("网络名称 SSID", wifi.ssid ?? (wifi.connected ? "系统未提供" : "未连接"))
                    detail("接入点 BSSID", wifi.bssid ?? "不可用")
                    detail("频段 / 信道 / 带宽", wifi.connected ? "\(wifi.band) · \(wifi.channel.map(String.init) ?? "?") · \(wifi.width)" : "不适用")
                }
                HStack(alignment: .top, spacing: 24) {
                    detail("RSSI · 接收信号", wifi.rssi.map { "\($0) dBm · \(SignalLevel.rssi($0).rawValue)" } ?? "不可用")
                    detail("噪声 / SNR", "\(wifi.noise.map { "\($0) dBm" } ?? "不可用") / \(wifi.snr.map { "\($0) dB" } ?? "不可用")")
                    detail("Tx 协商速率", wifi.txRate.map { String(format: "%.0f Mbps", $0) } ?? "不可用")
                }
                HStack(alignment: .top, spacing: 24) {
                    detail("无线制式", wifi.phy)
                    detail("安全模式", wifi.security)
                    detail("SNR 提示", wifi.snr.map { $0 >= 25 ? "较好" : $0 >= 15 ? "一般" : "较低，关注噪声或弱信号" } ?? "不可用")
                }
                if wifi.connected && (wifi.ssid == nil || wifi.bssid == nil) {
                    HStack {
                        Text(local.permissionGranted ? "已授权，但系统尚未返回 Wi-Fi 标识。" : "macOS 需要定位权限才能提供 SSID / BSSID；不会读取 GPS 位置。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(local.permissionGranted ? "重新读取" : local.permission == .denied || local.permission == .restricted ? "打开定位设置" : "允许读取 Wi-Fi 名称") { local.requestWiFiPermission() }
                    }.padding(12).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            } else { Text("当前没有可读取的 Wi-Fi 接口。有线或不受支持的设备不显示无线信号。") .foregroundStyle(.secondary) }
            if local.history.samples.contains(where: { $0.rssi != nil || $0.noise != nil }) {
                Chart(local.history.samples) { sample in
                    if let rssi = sample.rssi {
                        LineMark(x: .value("时间", sample.date), y: .value("dBm", rssi), series: .value("分段", "rssi-\(sample.segment)"))
                            .foregroundStyle(by: .value("指标", "信号 RSSI"))
                        PointMark(x: .value("时间", sample.date), y: .value("dBm", rssi)).foregroundStyle(accent).symbolSize(6)
                    }
                    if let noise = sample.noise {
                        LineMark(x: .value("时间", sample.date), y: .value("dBm", noise), series: .value("分段", "noise-\(sample.segment)"))
                            .foregroundStyle(by: .value("指标", "噪声"))
                    }
                }.chartForegroundStyleScale(["信号 RSSI": accent, "噪声": Color.gray])
                    .chartYScale(domain: -120...0).chartYAxisLabel("dBm · 越接近 0 越强")
                    .chartXScale(domain: value.date.addingTimeInterval(-600)...value.date)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second()) } }
                    .frame(height: 180)
            } else {
                Text("等待可用的信号样本；无读数时不会画成 0，也不会生成演示曲线。")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90)
            }
            Text("最近 10 分钟 · 每 2 秒观察 · 连接变化、缺失与暂停处断线。RSSI ≥ −60 dBm 提示为强，低于 −70 提示为弱；SNR ≥ 25 dB 提示较好，低于 15 提示较低。这些是排障参考阈值。")
                .font(.caption).foregroundStyle(.secondary)
            Text("SNR = 信号 − 噪声；信号与噪声间距越大，通常越容易分辨信号。Tx 为无线协商速率，不是互联网实测网速。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("路由与系统配置", systemImage: "gearshape.2").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                detail("系统默认 DNS", value.dns.isEmpty ? "未获取" : value.dns.joined(separator: "\n"))
                detail("系统代理开关", value.proxies.isEmpty ? "未发现全局代理开关开启" : value.proxies.joined(separator: " / "))
                detail("系统路径协议", "IPv4 \(value.path.ipv4 ? "可用" : "未报告") · IPv6 \(value.path.ipv6 ? "可用" : "未报告")")
            }
            Text("DNS 为系统全局默认配置，VPN 和分域解析可能另有规则。代理开关不证明每个应用都经过代理。默认接口为 utun/tun 等时可能存在虚拟路由，不能仅据此识别 VPN 供应商。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
    private func overview(_ title: String, _ text: String, _ help: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(color).textSelection(.enabled)
            Text(help).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.14)))
    }
    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func signalColor(_ level: SignalLevel) -> Color {
        switch level { case .good: return .green; case .fair: return .orange; case .poor: return .red; case .unknown: return .secondary }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
