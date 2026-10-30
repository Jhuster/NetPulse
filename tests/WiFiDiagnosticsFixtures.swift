import Foundation

enum WiFiDiagnosticsFixtures {
    static func snapshot() -> LocalNetworkSnapshot {
        var value = LocalNetworkSnapshot()
        value.primaryInterface = "en0"
        value.wifi = WiFiInfo(interface: "en0", power: true, connected: true, ssid: "Example Office", bssid: "02:00:00:00:00:01", rssi: -50, noise: -95, txRate: 600, channel: 36, band: "5 GHz", width: "80 MHz", phy: "802.11ax", security: "WPA2")
        return value
    }
    static func scan() -> WiFiScanResult {
        let networks = [
            WiFiAccessPoint(id: "a", ssid: "Example Office", bssid: "02:00:00:00:00:01", band: .ghz5, channel: 36, width: "80 MHz", rssi: -50, noise: -95, security: "WPA2 Enterprise"),
            WiFiAccessPoint(id: "b", ssid: "Example Guest", bssid: "02:00:00:00:00:02", band: .ghz5, channel: 36, width: "40 MHz", rssi: -65, noise: -96, security: "WPA2 Personal"),
            WiFiAccessPoint(id: "c", ssid: "Office, \"East\"\nExample", bssid: "02:00:00:00:00:03", band: .ghz5, channel: 149, width: "80 MHz", rssi: -72, noise: nil, security: "WPA3 Personal"),
            WiFiAccessPoint(id: "d", ssid: nil, bssid: nil, band: .ghz5, channel: 44, width: "20 MHz", rssi: nil, noise: nil, security: "未知"),
            WiFiAccessPoint(id: "e", ssid: "Example 2.4", bssid: "02:00:00:00:00:04", band: .ghz2, channel: 1, width: "20 MHz", rssi: -55, noise: -94, security: "WPA2 Personal")
        ]
        return WiFiScanResult(date: Date(), interface: "en0", networks: networks, total: networks.count)
    }
}
