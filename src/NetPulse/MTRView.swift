import SwiftUI
import Charts

struct MTRPanel: View {
    @ObservedObject var m: MTRStore
    @ObservedObject var route: RouteStore
    private var stats: MTRStats { m.targetStats }
    private var targetColor: Color { (stats.loss ?? 0) > 0 ? (stats.valid.count >= 5 ? .red : .orange) : stats.valid.isEmpty ? .secondary : .green }
    private var comparison: [MTRSample] { m.window.filter { $0.kind == "target" || ($0.kind == "hop" && $0.ttl == m.selectedTTL) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Text("持续观察").font(.headline)
                Text(m.imported ? "离线回放 · 当前时间窗" : "第 \(m.round) 轮 · 已观察到 TTL \(m.roundTTL)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("统计窗", selection: $m.span) { Text("60 秒").tag(60.0); Text("5 分钟").tag(300.0) }.frame(width: 160)
                Picker("路径段", selection: Binding(get: { m.selectedSegment }, set: { m.chooseSegment($0) })) {
                    if m.segments.isEmpty { Text("段 1").tag(1) }
                    ForEach(m.segments, id: \.self) { Text("段 \($0)").tag($0) }
                }.frame(width: 150)
                Button(m.imported ? "记录末尾" : m.follow ? "暂停跟随" : "回到实时") {
                    if m.imported { if let date = m.samples.last?.date { m.browse(date) } }
                    else if m.follow { m.follow = false } else { m.live() }
                }
            }
            HStack(spacing: 12) {
                metricCard("目标 Ping 丢包率", metric(stats.loss, unit: "%"), "\(stats.valid.count - stats.received) / \(stats.valid.count) 有效探测 · 错误 \(stats.errors)", targetColor)
                metricCard("目标平均 RTT", metric(stats.avg, unit: " ms"), "当前统计窗 · 当前路径段", .blue)
                metricCard("目标 P95 RTT", metric(stats.p95, unit: " ms"), "\(stats.rtts.count) 条回复 · 有限样本统计", .teal)
            }
            Text(explanation).font(.callout).foregroundStyle(targetColor)
            hopTable
            Text("回复率 / 无回复率属于该 TTL 的探针；无回复不能归因到某个 IP。平均和 P95 来自当前段的回复样本。不同采样频率与 ICMP 限速可能影响比较，不以某个中间节点未回复判定故障。")
                .font(.caption).foregroundStyle(.secondary)
            if let ttl = m.selectedTTL {
                let points = m.window.filter { $0.kind == "hop" && $0.ttl == ttl }
                HStack {
                    Text("已选第 \(ttl) 跳 · \(points.count) 条记录，下方与目标对照")
                    Spacer()
                    Text("P95 样本少时仅供参考")
                }.font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(m.selectedTTL.map { "目标 / 第 \($0) 跳 RTT 对照" } ?? "目标 RTT 时间线").font(.headline)
                    Spacer()
                    if m.selectedTTL != nil { Button("只看目标") { m.selectedTTL = nil } }
                }
                if comparison.contains(where: { $0.rtt != nil }) {
                    Chart(comparison.filter { $0.rtt != nil }) { p in
                        PointMark(x: .value("观察时间", p.date), y: .value("RTT ms", p.rtt!))
                            .foregroundStyle(by: .value("探测", p.kind == "target" ? "目标" : "第 \(p.ttl) 跳 · \(p.address)"))
                    }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }.chartYAxisLabel("RTT (ms)")
                        .chartXScale(domain: m.endDate.addingTimeInterval(-m.span)...m.endDate).frame(height: 155)
                } else { Text("等待有效回复；超时不补成 0 ms。").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120) }
                Text("目标 Ping 丢包率 · 5 秒窗口").font(.subheadline.weight(.medium))
                Chart(m.targetLoss) { p in
                    BarMark(x: .value("观察时间", p.date), y: .value("丢包率 %", p.loss), width: .fixed(5)).foregroundStyle(.pink)
                    if p.loss == 0 { PointMark(x: .value("观察时间", p.date), y: .value("丢包率 %", 0)).symbolSize(10).foregroundStyle(.pink) }
                }.chartYScale(domain: 0...100).chartXScale(domain: m.endDate.addingTimeInterval(-m.span)...m.endDate)
                    .chartYAxisLabel("%").frame(height: 85)
                Text("RTT 点按实际观察时刻显示，不跨缺失补线；丢包率仅统计真实 reply / timeout，未完成和系统错误不算丢包。当前末尾五秒窗可能尚未完成。")
                    .font(.caption).foregroundStyle(.secondary)
                if !m.samples.isEmpty {
                    HStack {
                        Text("浏览历史").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { min(m.historyRange.upperBound, max(m.historyRange.lowerBound, m.endDate.timeIntervalSince1970)) }, set: { m.browse(Date(timeIntervalSince1970: $0)) }), in: m.historyRange)
                        Text(m.endDate, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit())
                    }
                }
            }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 10))

        }
    }
    private var explanation: String {
        if stats.valid.isEmpty { return "尚无目标有效样本，不能评价目标稳定性。逐跳静默路径会使采样变慢。" }
        if stats.valid.count < 5 { return "目标样本不足 5 个，先观察更长时间；不据此定位故障节点。" }
        if (stats.loss ?? 0) > 0 { return "当前窗口目标存在 ICMP 未回复。请结合时间线与后续节点核查；不能直接确定故障起点或业务丢包。" }
        return "当前窗口目标探针均有回复。中间节点即使无回复，也可能只是 ICMP 限速或不响应。"
    }
    private var hopTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TTL / 节点 · 归属").frame(maxWidth: .infinity, alignment: .leading)
                Text("回复率").frame(width: 65, alignment: .trailing)
                Text("无回复率").frame(width: 70, alignment: .trailing)
                Text("平均 / P95 ms").frame(width: 125, alignment: .trailing)
                Text("近期 RTT").frame(width: 80)
                Text("状态 / 样本").frame(width: 135, alignment: .leading)
            }.font(.caption).foregroundStyle(.secondary).padding(12)
            Divider()
            if m.rows.isEmpty { Text("当前时间窗 / 路径段暂无逐跳样本，等待当前或下一轮补齐。").font(.callout).foregroundStyle(.secondary).padding(24) }
            ForEach(m.rows) { row in
                Button { m.selectedTTL = row.id } label: {
                    HStack(alignment: .center) {
                        HStack(alignment: .top, spacing: 10) {
                            Text(String(row.id)).monospacedDigit().frame(width: 25, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                if row.stats.addresses.isEmpty { Text("未识别节点").foregroundStyle(.secondary) }
                                ForEach(row.stats.addresses, id: \.self) { ip in
                                    HStack {
                                        Text(ip).font(.system(.callout, design: .monospaced))
                                        if ip == route.gateway && m.selectedSegment == m.segment { Text("网关").font(.caption).foregroundStyle(.blue) }
                                        if ip == route.targetIP { Text("目标").font(.caption).foregroundStyle(.blue) }
                                    }
                                    Text(geoText(ip, row.stats.samples)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(metric(row.stats.response, unit: "%")).monospacedDigit().frame(width: 65, alignment: .trailing)
                        Text(metric(row.stats.loss, unit: "%")).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text(row.stats.addresses.count > 1 ? "多地址 · 分开查看" : "\(metric(row.stats.avg)) / \(metric(row.stats.p95))").monospacedDigit().frame(width: 125, alignment: .trailing)
                        Chart(row.stats.samples.filter { $0.rtt != nil }) { p in
                            PointMark(x: .value("时间", p.date), y: .value("RTT", p.rtt!)).symbolSize(8).foregroundStyle(.blue)
                        }.chartXAxis(.hidden).chartYAxis(.hidden).chartXScale(domain: m.endDate.addingTimeInterval(-m.span)...m.endDate).frame(width: 80, height: 28).accessibilityLabel("近期 RTT 样本")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.stats.received == 0 ? "无回复 · 未知" : row.stats.samples.contains(where: { !$0.annotation.isEmpty }) ? "异常 ICMP · 核查" : row.stats.received < row.stats.valid.count ? "仅探测回复不足" : "收到回复")
                                .foregroundStyle(row.stats.received == 0 ? Color.secondary : row.stats.received < row.stats.valid.count || row.stats.samples.contains(where: { !$0.annotation.isEmpty }) ? .orange : .green)
                            Text("\(row.stats.received) / \(row.stats.valid.count) · 错误 \(row.stats.errors)").foregroundStyle(.secondary)
                        }.font(.caption).frame(width: 135, alignment: .leading)
                    }.padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain).background(m.selectedTTL == row.id ? Color.blue.opacity(0.08) : .clear)
                Divider()
            }
        }.background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
    private func geoText(_ ip: String, _ samples: [MTRSample]) -> String {
        if nonPublicAddress(ip) { return "内网 / 共享地址 · 地域不适用" }
        if let p = samples.last(where: { $0.address == ip && (!$0.country.isEmpty || !$0.province.isEmpty) }) { return "\(p.country.isEmpty ? "国家未知" : p.country) · \(p.province.isEmpty ? "省份未知" : p.province)" }
        return "国家未知 · 省份未知"
    }
    private func metricCard(_ title: String, _ value: String, _ detail: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
}
