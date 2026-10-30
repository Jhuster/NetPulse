// Optional layout harness; not compiled into the released application.
import SwiftUI

@main struct WiFiDiagnosticsPreview: App {
    @StateObject private var local = LocalNetworkStore(reader: { _ in WiFiDiagnosticsFixtures.snapshot() }, scanner: { _ in WiFiDiagnosticsFixtures.scan() }, scanPermission: { true })
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("布局验证 · 合成示例数据，非真实网络或扫描结果").font(.headline).foregroundStyle(.orange)
                    WiFiNearbyView().environmentObject(local)
                }.padding(20)
            }.frame(minWidth: 900, minHeight: 680)
                .onAppear { local.accept(WiFiDiagnosticsFixtures.snapshot()) }
        }.defaultSize(width: 1000, height: 800)
    }
}
