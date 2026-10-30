import SwiftUI
import Charts

struct SpeedView: View {
    @EnvironmentObject var s: SpeedStore
    @EnvironmentObject var workspaces: Workspaces
    private let blue = Color(red: 0.12, green: 0.49, blue: 0.78)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("网络测速").font(.title2.bold())
                        Text("测量吞吐量，也看看带宽被占满时，网络是否仍然顺畅。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("导入日志", systemImage: "square.and.arrow.down") { workspaces.pickImport(.speed) }.disabled(s.running)
                    Button(s.running ? "停止测速" : "开始测速", systemImage: s.running ? "stop.fill" : "play.fill") { s.running ? s.stop() : s.begin() }.buttonStyle(.borderedProminent).disabled(s.stopping)
                }
                HStack(spacing: 20) {
                    Picker("测量服务", selection: $s.provider) { ForEach(SpeedProvider.allCases) { Text($0.title).tag($0) } }.frame(width: 290)
                    if s.provider == .cloudflare {
                        Picker("测试数据预算", selection: $s.budgetMB) { Text("64 MB · 日常检测").tag(64); Text("256 MB · 高速线路").tag(256) }.frame(width: 270)
                    } else { Text("最长 30 秒 · 无流量上限").foregroundStyle(.orange) }
                    Spacer()
                }.disabled(s.running)
                Text(s.provider == .cloudflare ? "请求发往 speed.cloudflare.com，服务商会看到出口 IP；不额外上传测量结果。预算限制测试负载，不含协议开销、重传和后台流量。丢包未测。" : "调用 macOS networkQuality，顺序测量下载和上传。服务节点由系统选择，流量无法设上限；等待系统返回最终统计。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if s.running { ProgressView().controlSize(.small) }
                    Label(s.phase, systemImage: s.imported ? "clock.arrow.circlepath" : "speedometer").font(.headline)
                    Spacer()
                    Text("\(s.recordProvider.title) · \(Int(s.elapsed)) 秒").monospacedDigit().foregroundStyle(.secondary)
                    if s.recordProvider == .cloudflare { Text(String(format: "已调度 %.2f MB 测试数据", Double(s.scheduledBytes) / 1_000_000)).foregroundStyle(.secondary) }
                }
                HStack(spacing: 12) {
                    card("下载", s.summary.values["download"].map { $0 / 1_000_000 }, "Mbps", "服务节点到本机", blue)
                    card("上传", s.summary.values["upload"].map { $0 / 1_000_000 }, "Mbps", "本机到服务节点", .teal)
                    card("空闲时延", s.summary.values["latency"], "ms", s.recordProvider == .cloudflare ? "HTTP 往返 · 非 Ping" : "系统 base RTT", .orange)
                    card("空闲抖动", s.summary.values["jitter"], "ms", s.recordProvider == .cloudflare ? "引擎时延波动" : "系统未提供此项", .purple)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("负载下的响应").font(.headline)
                    HStack(spacing: 30) {
                        loaded("下载占满时", key: "downLoadedLatency")
                        loaded("上传占满时", key: "upLoadedLatency")
                        Spacer()
                        if s.recordProvider == .system {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("系统响应能力（RPM）").font(.subheadline.weight(.medium))
                                Text("下载 \(metric(s.summary.values["dl_responsiveness"])) / 上传 \(metric(s.summary.values["ul_responsiveness"]))")
                            }
                        }
                    }
                    Text("与空闲时延比较可观察排队影响；不同服务、测量方法和节点的结果请分别比较。缺失项显示 —，不按 0 处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("请求吞吐量采样").font(.headline); Spacer(); Text("下载 / 上传").font(.caption).foregroundStyle(.secondary) }
                    if s.samples.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "speedometer").font(.system(size: 40)).foregroundStyle(blue.opacity(0.7))
                            Text(s.recordProvider == .system ? "系统对照仅提供最终统计，不生成过程曲线" : "开始后在这里观察每次测量请求的吞吐量")
                            Text("不会自动开始测速，也不会循环消耗流量").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        Chart(s.samples) { p in
                            PointMark(x: .value("时间", p.date), y: .value("Mbps", p.bps / 1_000_000))
                                .foregroundStyle(by: .value("方向", p.kind == "download" ? "下载" : "上传"))
                        }.chartForegroundStyleScale(["下载": blue, "上传": Color.teal])
                            .chartYAxisLabel("Mbps").frame(height: 200)
                    }
                    Text("每个点代表一次请求的吞吐量，非网卡瞬时速率。小负载或过短请求可能无法跑满高速线路，结果不等同于宽带合约带宽。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
                Label(s.notice, systemImage: "info.circle").font(.callout).textSelection(.enabled)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("每次测速单独存档").font(.headline)
                        Text(s.logURL?.path ?? "开始后自动创建 summary.csv、samples.csv 和 network-context.txt")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("在 Finder 中显示", systemImage: "folder") { s.reveal() }.disabled(s.logURL == nil)
                    Button("导出日志", systemImage: "square.and.arrow.up") { s.export() }.disabled(s.logURL == nil || s.running)
                }
                DisclosureGroup("最近 20 次测速 · 点击离线查看") {
                    VStack(alignment: .leading, spacing: 8) {
                        if s.history.isEmpty { Text("暂无历史记录").foregroundStyle(.secondary) }
                        ForEach(s.history) { item in Button(item.title) { s.load(item.url) }.disabled(s.running).buttonStyle(.link) }
                    }.padding(.top, 8)
                }
            }.padding(26)
        }
    }
    private func loaded(_ title: String, key: String) -> some View {
        let value = s.summary.values[key]
        let delta = value.flatMap { load in s.summary.values["latency"].map { load - $0 } }
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium))
            Text(metric(value, unit: " ms")).font(.title3.monospacedDigit())
            Text(delta.map { String(format: "比空闲 %+.2f ms", $0) } ?? "等待有效测量").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func card(_ title: String, _ value: Double?, _ unit: String, _ detail: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Text(metric(value, unit: " " + unit)).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(color).minimumScaleFactor(0.65).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}
