import SwiftUI

struct TargetInput: View {
    @Binding var target: String
    var title: String
    var locked: Bool
    var onChangeTarget: () -> Void
    @FocusState private var focused: Bool
    private let blue = Color(red: 0.12, green: 0.34, blue: 0.76)
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("目标地址", systemImage: "scope").font(.subheadline.weight(.semibold))
                Text("仅用于\(title)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if locked { Label("当前测试已锁定", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 12) {
                Image(systemName: "network").font(.title3).foregroundStyle(blue)
                if locked {
                    Text(target).font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundStyle(.primary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("输入域名或 IPv4 地址，例如 example.com", text: $target).textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .medium, design: .monospaced)).focused($focused)
                        .accessibilityLabel("\(title)目标地址")
                }
                if locked { Button("更换目标", action: onChangeTarget) }
            }.padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(locked ? Color.secondary.opacity(0.35) : blue.opacity(focused ? 1 : 0.6), lineWidth: focused && !locked ? 2 : 1.5))
            Text(locked ? "更换目标将新建当前测试，其他工作区不受影响，原日志保留。" : "当前工作区独立设置目标，不影响其他工作区。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}
