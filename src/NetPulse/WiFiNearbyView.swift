import SwiftUI
import Charts

struct WiFiNearbyView: View {
    @EnvironmentObject var local: LocalNetworkStore
    @State private var band: WiFiBand = .ghz5
    @State private var search = ""
    @State private var showEvents = false
    @State private var selectedID: String?
    private var rows: [WiFiAccessPoint] {
        (local.nearbyScan?.networks ?? []).filter {
            $0.band == band && (search.isEmpty || ($0.ssid ?? "").localizedCaseInsensitiveContains(search) || ($0.bssid ?? "").localizedCaseInsensitiveContains(search))
        }
    }
    private var current: WiFiInfo? {
        guard !local.scanStale, local.nearbyScan?.interface == local.snapshot.wifi?.interface else { return nil }
        return local.snapshot.wifi
    }
    private var channelTicks: [Int] {
        let values = Array(Set(rows.compactMap(\.channel))).sorted()
        let step = max(1, Int(ceil(Double(values.count) / 12)))
        return values.enumerated().filter { $0.offset % step == 0 || $0.offset == values.count - 1 }.map(\.element)
    }
    private var channelDomain: ClosedRange<Double> {
        let values = rows.compactMap(\.channel)
        let margin = band == .ghz2 ? 1.0 : 4.0
        return max(0, Double(values.min() ?? 1) - margin)...(Double(values.max() ?? 1) + margin)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("周边 Wi-Fi 与信道", systemImage: "dot.radiowaves.left.and.right").font(.headline)
                Spacer()
                if local.scanBusy { ProgressView().controlSize(.small) }
                if local.scanWaiting { Button("结束等待") { local.stopWaitingForScan() } }
                Button(local.nearbyScan == nil ? "扫描周边 Wi-Fi" : "重新扫描", systemImage: "magnifyingglass") { local.scanNearby() }
                    .buttonStyle(.borderedProminent).disabled(local.scanBusy || local.reading || !local.canScanNearby)
            }
            if !local.canScanNearby {
                HStack {
                    Text("周边网络标识受 macOS 定位权限保护；不读取 GPS，不上传扫描结果。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(local.permission == .denied || local.permission == .restricted ? "打开定位设置" : "允许扫描所需权限") { local.requestWiFiPermission() }
                }
            }
            Text(local.scanMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let result = local.nearbyScan {
                HStack {
                    Text("\(result.interface) · \(result.date.formatted()) · 共 \(result.networks.count) 条记录").font(.caption).foregroundStyle(.secondary)
                    if local.scanStale { Label("旧快照", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                }
                HStack {
                    Picker("频段", selection: $band) {
                        ForEach(WiFiBand.allCases) { band in Text(band.rawValue).tag(band) }
                    }.pickerStyle(.segmented).frame(width: 330)
                    Spacer()
                    TextField("搜索名称 / BSSID", text: $search).textFieldStyle(.roundedBorder).frame(width: 240)
                }
                if rows.isEmpty {
                    Text("当前频段或筛选条件下没有结果；这不证明附近没有无线网络。")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70)
                } else {
                    let points = rows.filter { $0.channel != nil && $0.rssi != nil }
                    if !points.isEmpty {
                        Chart(points) { ap in
                            PointMark(x: .value("主信道", ap.channel!), y: .value("RSSI", ap.rssi!))
                                .foregroundStyle(ap.isCurrent(current) ? Color.blue : ap.id == selectedID ? .orange : .gray.opacity(0.7))
                                .symbolSize(ap.isCurrent(current) || ap.id == selectedID ? 90 : 35)
                                .annotation(position: .top) { if ap.id == selectedID { Text(ap.ssid ?? "名称不可用").font(.caption2).lineLimit(1) } }
                        }.chartYScale(domain: -120...0).chartYAxisLabel("RSSI (dBm)")
                            .chartXScale(domain: channelDomain)
                            .chartXAxis { AxisMarks(values: channelTicks) { AxisGridLine(); AxisValueLabel() } }
                            .chartXAxisLabel("主信道 · \(band.rawValue)").frame(height: 170)
                        HStack {
                            Label("可匹配的当前接入点", systemImage: "circle.fill").foregroundStyle(.blue)
                            Label("其他扫描记录", systemImage: "circle.fill").foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                    HStack(spacing: 12) {
                        Text("网络 / 接入点").frame(maxWidth: .infinity, alignment: .leading)
                        Text("主信道 / 带宽").frame(width: 150, alignment: .leading)
                        Text("RSSI").frame(width: 70, alignment: .trailing)
                        Text("安全模式").frame(width: 155, alignment: .leading)
                    }.font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { ap in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(ap.ssid?.isEmpty == false ? ap.ssid! : "名称不可用").font(.subheadline.weight(.medium)).lineLimit(2)
                                            if ap.isCurrent(current) { Text("当前接入点").font(.caption2).foregroundStyle(.blue) }
                                        }
                                        Text(ap.bssid ?? "BSSID 不可用").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(ap.channel.map(String.init) ?? "未知") · \(ap.width)").font(.caption).frame(width: 150, alignment: .leading)
                                    Text(ap.rssi.map { "\($0) dBm" } ?? "未知").font(.caption).monospacedDigit().frame(width: 70, alignment: .trailing)
                                    Text(ap.security).font(.caption).frame(width: 155, alignment: .leading)
                                }.padding(.vertical, 9).textSelection(.enabled).contentShape(Rectangle())
                                    .background(selectedID == ap.id ? Color.blue.opacity(0.05) : .clear)
                                    .onTapGesture { selectedID = ap.id }
                                    .help("噪声：\(ap.noise.map { "\($0) dBm" } ?? "未知")；SNR：\(ap.snr.map { "\($0) dB" } ?? "未知")")
                                Divider()
                            }
                        }
                    }.frame(height: min(320, CGFloat(rows.count) * 58))
                }
            }
            Text("点击一行可在图中定位。图示主信道与 RSSI，带宽另列；同/邻信道只提示可能重叠，不代表实际拥塞。宽信道占用范围尚未解析，不自动推荐信道。")
                .font(.caption).foregroundStyle(.secondary)
            Text("扫描可能短时影响无线时延，不会自动连接或切换网络。记录数可能因权限、隐藏网络及系统合并而少于实际 AP 数量。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup("连接变化记录（\(local.connections.events.count)，最多保留 200 条）", isExpanded: $showEvents) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("约每 2 秒观察一次，只记录观察到的变化；同名网络的 BSSID 变化不等于已经测量漫游性能，暂停期间不补猜事件。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(local.connections.events.suffix(20).reversed()) { event in
                        HStack(alignment: .top, spacing: 16) {
                            Text(event.date.formatted(date: .omitted, time: .standard)).font(.caption).monospacedDigit().frame(width: 70, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.kind).font(.subheadline.weight(.medium))
                                Text(event.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    Text("页面显示最近 20 条，导出包含当前保留的全部记录。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            .onAppear { if let wifi = local.snapshot.wifi, let band = WiFiBand(rawValue: wifi.band) { self.band = band } }
    }
}
