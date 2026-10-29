import SwiftUI

struct GeoSettingsView: View {
    @EnvironmentObject var route: RouteStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("IP 地理归属", systemImage: "globe.asia.australia.fill").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("安装一次，之后自动离线查询国家和省份。无需定位权限，也不会把路径 IP 发送给地理服务。")
                .foregroundStyle(.secondary)
            if let database = route.geoDatabase {
                VStack(alignment: .leading, spacing: 8) {
                    Label("数据库已安装", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(database.source).textSelection(.enabled)
                    Link(database.attribution, destination: database.attributionURL).font(.caption)
                    Text("日期为数据构建日期；可导入新版文件更新。历史日志继续使用当时的归属快照。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("自动下载并安装").font(.headline)
                Text("使用 DB-IP City Lite，约百 MB。点击后会从官方网站下载最新数据库，自动解压、校验并启用；之后离线查询。更新时先验证新库，失败继续使用旧库。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Link("数据来源：DB-IP ↗", destination: GeoDownload.page)
                    Text("·").foregroundStyle(.secondary)
                    Link("CC BY 4.0 许可 ↗", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }.font(.caption)
                Button(route.geoDatabase == nil ? "下载并启用" : "下载最新数据库", systemImage: "arrow.down.circle.fill") { route.downloadGeoDatabase() }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(route.geoLoading || route.imported)
                if route.geoDownloading {
                    if let progress = route.geoDownloadProgress { ProgressView(value: progress) }
                    else { ProgressView().controlSize(.small) }
                    Button("取消下载") { route.cancelGeoDownload() }
                }
            }
            HStack {
                if route.geoLoading { ProgressView().controlSize(.small) }
                Text(route.geoMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("从本地文件安装").font(.subheadline.bold())
                    Text("备用方式：选择 .mmdb 或 .mmdb.gz。支持 DB-IP 与 GeoLite / GeoIP City、Country，不支持 IP2Location BIN。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("导入数据库…") { route.importGeoDatabase() }.disabled(route.geoLoading || route.imported)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("自定义 IP 归属覆盖表").font(.subheadline.bold())
                    Text("可选 UTF-8 CSV：ip,country,province。按精确 IP 匹配，优先于数据库；仅当前应用运行期间保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("导入覆盖表…") { route.importGeo() }.disabled(route.imported)
            }
            if route.imported {
                Text("当前为离线回放，保留日志原有地理归属。新建测试后可安装数据库或导入覆盖表。")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("归属数据可能缺失或有误，不能代表路由器、机房或光纤的实测位置。内网/共享和保留地址不查询。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 570, height: 600)
    }
}
