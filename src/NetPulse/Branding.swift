import SwiftUI
import AppKit

@MainActor enum Branding {
    static let icon: NSImage? = {
        let file = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "NetPulse.icns"
        return Bundle.main.url(forResource: file, withExtension: nil).flatMap { NSImage(contentsOf: $0) }
    }()
}
struct AppLogo: View {
    var body: some View {
        Group {
            if let icon = Branding.icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.blue)
            }
        }.frame(width: 48, height: 48).accessibilityHidden(true)
    }
}
