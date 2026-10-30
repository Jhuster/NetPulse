import Foundation
import SystemConfiguration
import CoreWLAN
import Darwin

enum LocalNetworkReader {
    static func read(path: LocalPathInfo) -> LocalNetworkSnapshot {
        var snapshot = LocalNetworkSnapshot(); snapshot.path = path
        let store = SCDynamicStoreCreate(nil, "NetPulse Local Network" as CFString, nil, nil)
        func value(_ key: String) -> [String: Any] {
            guard let store else { return [:] }
            return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
        }
        let v4 = value("State:/Network/Global/IPv4"), v6 = value("State:/Network/Global/IPv6")
        snapshot.primaryInterface = v4["PrimaryInterface"] as? String ?? v6["PrimaryInterface"] as? String ?? ""
        snapshot.gateway4 = v4["Router"] as? String ?? ""
        snapshot.gateway6 = v6["Router"] as? String ?? ""
        snapshot.dns = value("State:/Network/Global/DNS")["ServerAddresses"] as? [String] ?? []
        let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        for (key, title) in [("HTTPEnable", "HTTP"), ("HTTPSEnable", "HTTPS"), ("SOCKSEnable", "SOCKS"), ("ProxyAutoConfigEnable", "自动代理 PAC"), ("ProxyAutoDiscoveryEnable", "自动发现 WPAD")] {
            if (proxies[key] as? NSNumber)?.boolValue == true { snapshot.proxies.append(title) }
        }
        if store == nil { snapshot.issue = "系统网络配置不可读取；部分地址和 DNS 可能缺失" }
        var labels: [String: (String, String)] = [:]
        for item in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(item) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(item) as String?
            let kind: String
            if type == kSCNetworkInterfaceTypeIEEE80211 as String { kind = "Wi-Fi" }
            else if type == kSCNetworkInterfaceTypeEthernet as String { kind = "有线 / 以太网" }
            else if type == kSCNetworkInterfaceTypeWWAN as String { kind = "移动网络" }
            else { kind = type ?? "其他" }
            labels[name] = (SCNetworkInterfaceGetLocalizedDisplayName(item) as String? ?? name, kind)
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&head) == 0 {
            defer { freeifaddrs(head) }
            var cursor = head; var items: [String: LocalInterfaceInfo] = [:]
            while let pointer = cursor {
                let item = pointer.pointee; cursor = item.ifa_next
                let name = String(cString: item.ifa_name)
                if name == "lo0" { continue }
                let isVirtual = name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("tap") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("bridge") || name.hasPrefix("anpi") || name.hasPrefix("gif") || name.hasPrefix("stf")
                let up = Int(item.ifa_flags) & Int(IFF_UP) != 0 && Int(item.ifa_flags) & Int(IFF_RUNNING) != 0
                if items[name] == nil { items[name] = LocalInterfaceInfo(id: name, name: labels[name]?.0 ?? name, kind: labels[name]?.1 ?? (isVirtual ? "虚拟 / 系统接口" : "其他"), addresses: [], up: up, virtual: isVirtual) }
                guard let address = item.ifa_addr, [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: buffer)
                    if !items[name]!.addresses.contains(ip) { items[name]!.addresses.append(ip) }
                }
            }
            snapshot.interfaces = items.values.map { item in var item = item; item.addresses.sort(); return item }.sorted { $0.id < $1.id }
        } else { snapshot.issue = "本机接口地址读取失败" }
        let client = CWWiFiClient()
        let radios = (client.interfaces() ?? []).sorted { ($0.interfaceName ?? "") < ($1.interfaceName ?? "") }
        let selected = radios.first { $0.interfaceName == snapshot.primaryInterface } ?? radios.first { $0.wlanChannel() != nil } ?? radios.first
        if let radio = selected {
            let channel = radio.wlanChannel()
            let connected = radio.powerOn() && channel != nil
            let bands = [1: "2.4 GHz", 2: "5 GHz", 3: "6 GHz"]
            let widths = [1: "20 MHz", 2: "40 MHz", 3: "80 MHz", 4: "160 MHz", 5: "320 MHz"]
            let modes = [1: "802.11a", 2: "802.11b", 3: "802.11g", 4: "802.11n / Wi-Fi 4", 5: "802.11ac / Wi-Fi 5", 6: "802.11ax / Wi-Fi 6", 7: "802.11be / Wi-Fi 7"]
            let security = [0: "开放网络", 1: "WEP", 2: "WPA Personal", 3: "WPA/WPA2 Personal", 4: "WPA2 Personal", 5: "Personal", 6: "Dynamic WEP", 7: "WPA Enterprise", 8: "WPA/WPA2 Enterprise", 9: "WPA2 Enterprise", 10: "Enterprise", 11: "WPA3 Personal", 12: "WPA3 Enterprise", 13: "WPA2/WPA3 Personal", 14: "OWE", 15: "OWE Transition"]
            let rate = radio.transmitRate()
            snapshot.wifi = WiFiInfo(interface: radio.interfaceName ?? "Wi-Fi", power: radio.powerOn(), connected: connected,
                ssid: connected ? radio.ssid() : nil, bssid: connected ? radio.bssid() : nil,
                rssi: connected ? wifiDBM(radio.rssiValue()) : nil, noise: connected ? wifiDBM(radio.noiseMeasurement()) : nil,
                txRate: connected && rate.isFinite && rate > 0 ? rate : nil,
                channel: channel.map { Int($0.channelNumber) }, band: channel.flatMap { bands[Int($0.channelBand.rawValue)] } ?? "未知",
                width: channel.flatMap { widths[Int($0.channelWidth.rawValue)] } ?? "未知", phy: connected ? modes[Int(radio.activePHYMode().rawValue)] ?? "未知" : "未连接",
                security: connected ? security[Int(radio.security().rawValue)] ?? "未知" : "未连接")
        }
        return snapshot
    }
}
