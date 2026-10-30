import Foundation
import CoreWLAN

enum WiFiScanner {
    static func scan(interface: String) throws -> WiFiScanResult {
        let client = CWWiFiClient()
        guard let radio = client.interface(withName: interface) else { throw WiFiScanError.unavailable }
        guard radio.powerOn() else { throw WiFiScanError.poweredOff }
        // Blocking public API: always called on a utility task. No directed scan
        // for a hidden SSID, association changes or network uploads are performed.
        let networks = try radio.scanForNetworks(withSSID: nil, includeHidden: false)
        let mapped = networks.map { network -> WiFiAccessPoint in
            let channel = network.wlanChannel
            let bands: [Int: WiFiBand] = [1: .ghz2, 2: .ghz5, 3: .ghz6]
            let widths = [1: "20 MHz", 2: "40 MHz", 3: "80 MHz", 4: "160 MHz", 5: "320 MHz"]
            let options: [(CWSecurity, String)] = [(.wpa3Personal, "WPA3 Personal"), (.wpa3Enterprise, "WPA3 Enterprise"), (.wpa3Transition, "WPA2/WPA3"), (.wpa2Personal, "WPA2 Personal"), (.wpa2Enterprise, "WPA2 Enterprise"), (.wpaPersonal, "WPA Personal"), (.WEP, "WEP"), (.OWE, "OWE"), (.none, "开放")]
            let security = options.filter { network.supportsSecurity($0.0) }.map(\.1).joined(separator: " / ")
            let bssid = network.bssid?.lowercased()
            let band = channel.flatMap { bands[Int($0.channelBand.rawValue)] } ?? .unknown
            let id = (bssid ?? UUID().uuidString) + "|" + band.rawValue + "|" + (channel.map { String($0.channelNumber) } ?? "")
            return WiFiAccessPoint(id: id, ssid: network.ssid, bssid: bssid, band: band,
                channel: channel.map { Int($0.channelNumber) }, width: channel.flatMap { widths[Int($0.channelWidth.rawValue)] } ?? "未知",
                rssi: wifiDBM(network.rssiValue), noise: wifiDBM(network.noiseMeasurement), security: security.isEmpty ? "未知" : security)
        }.sorted {
            if $0.rssi != $1.rssi { return ($0.rssi ?? -999) > ($1.rssi ?? -999) }
            return $0.id < $1.id
        }
        var ids = Set<String>()
        let unique = mapped.filter { ids.insert($0.id).inserted }
        return WiFiScanResult(date: Date(), interface: interface, networks: Array(unique.prefix(512)), total: unique.count)
    }
}
