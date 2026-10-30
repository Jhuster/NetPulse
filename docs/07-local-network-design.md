# 本机网络 TAB：调研、需求与设计

日期：2026-10-29。当前实现平台为 macOS；后续平台分别评估系统 API 和权限，不承诺相同字段可用。

## 产品参考与取舍

| 参考 | 官方展示重点 | NetPulse 本轮采用 |
| --- | --- | --- |
| [NetSpot Inspector](https://www.netspotapp.com/netspot-mac.html) | AP 列表、RSSI/噪声、信道及信号图；另有勘测热力图 | 当前连接优先，原始 dBm 与中文解释并列，信号随时间变化 |
| [WiFi Explorer](https://www.intuitibits.com/products/wifiexplorer/) | 网络列表、频段/信道图、信号趋势、SSID/BSSID、安全与能力字段 | 信息分层，保留信道/频段/带宽与连接速率，详细地址另列 |
| [Apple 无线诊断](https://support.apple.com/en-gb/guide/mac-help/mchlf4de377f/27/mac/27) | 系统诊断与可交给支持人员的诊断文件 | 一键导出可读快照及信号 CSV，明确采集来源 |

首轮先完成本机连接观察。2026-10-30 的后续增量已加入按需周边扫描、主信道分布与观察到的连接变化，见 [周边 Wi-Fi 设计](08-wifi-nearby-design.md)。尚不做楼层图勘测/热力图、无线抓包或自动切换信道；AP 数量不等于空口占用率，不能据此伪造“拥塞百分比”。

## 信息与解释

- **本机接入**：Wi‑Fi、有线、系统报告的蜂窝或其他；接口、局域网地址、默认网关。全接口列表包括 IPv4/IPv6，区分虚拟接口。Wi‑Fi 热点只证明 Mac 到热点走 Wi‑Fi，不能推断手机是 4G/5G 或读取其蜂窝信号。
- **互联网出口**：用户点击查询，向 [IP.SB HTTPS API](https://ip.sb/api/) 发起不带本地字段的请求，显示该请求观察到的 IP、ISP/ASN 组织与来源/时间。服务商会看到该请求的出口 IP；不上传局域网 IP、SSID 或 BSSID。VPN/代理/目的地路由可能导致出口与 Ping 不同；网络变化后旧结果标为过期，查询失败不展示为当前结果。
- **Wi‑Fi 信号**：RSSI（dBm）、噪声（dBm）、SNR = RSSI − 噪声（dB）。RSSI ≥ −60 为强，−60 到 −70 为一般，低于 −70 为弱；SNR ≥ 25 为较好，15–25 为一般，低于 15 为较低。这是本工具的排障提示阈值，不是质量保证或统一标准。缺失指标显示不可用，0 不当成极强信号。图保留最近 10 分钟，切换连接、采集暂停及缺失处断线。
- **Wi‑Fi 配置**：SSID/BSSID、频段、信道、带宽、PHY、安全模式、Tx 协商速率。协商速率不是实测网速；有线连接无无线信号，显示不适用。可同时显示已连接但非默认上网接口的 Wi‑Fi，明确接口名称。
- **值得补充**：系统默认 DNS、IPv4/IPv6 配置、低数据/高成本路径、代理开关、虚拟接口提示、网络变化时间。系统路径“可用”只是系统路由判断，不代表已经验证互联网连通。

## 权限与系统依据

使用 `NWPathMonitor`、SystemConfiguration、`getifaddrs` 和 CoreWLAN 的公开 API，不使用已弃用 airport 私有工具、不要求管理员权限、不修改网络配置。

Apple 当前 SDK 的 `CWInterface.h` 明确说明 SSID/BSSID 需要开启定位服务并授权调用应用。参考 [SSID](https://developer.apple.com/documentation/corewlan/cwinterface/ssid%28%29)、[RSSI](https://developer.apple.com/documentation/corewlan/cwinterface/rssivalue%28%29)、[噪声](https://developer.apple.com/documentation/corewlan/cwinterface/noisemeasurement%28%29) 与 [Core Location 授权](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services)。RSSI/噪声发生错误或未连接时可返回 0，必须作为缺失处理。

页面可在未授权时先展示其他可读字段，用户点击“允许读取 Wi‑Fi 名称”才请求定位权限；拒绝或设备不支持时明确提示。仅用授权解锁 Wi‑Fi 标识，不调用 GPS 定位、不读取经纬度。不同系统和硬件仍可能不给出字段，不能承诺授权后一定完整。

## 交互与生命周期

第三个 TAB“本机网络”，不提供目标地址，不改变 Ping/路径会话。顶部四张卡：接入方式、局域网 IP、默认网关、Wi‑Fi 信号。下一层为独立的出口查询、Wi‑Fi 指标/趋势、DNS 与代理、接口列表。状态使用颜色加文字，避免仅靠红绿。

进入本 TAB 后每 2 秒后台读取一次本地快照；离开时停止定时采样，已有趋势保留；手动暂停跨 TAB 切换保留，直到点击继续。系统网络变化会更新快照并使出口结果失效；外部查询不定时自动发起。提供暂停/继续观察、手动刷新和导出。断开、权限不足、VPN、多接口、无 Wi‑Fi 都应正常展示，不使用演示数据替代。

导出新的 `.netpulse` 目录，包含 `network.txt`（可读快照）与 `wifi.csv`（时间、连接分段、接口、RSSI、噪声、SNR、Tx 速率）。不自动记录周边 SSID。导出前在界面说明文件包含本机地址和可用的 Wi‑Fi 标识；不混入 Ping/路径 CSV，不提供伪造回放。

## 验证边界

测试覆盖缺失与零值、信号提示阈值、SNR、趋势断线/网络分段、出口响应与变化后的过期处理、导出字段和第三 TAB 的工作区隔离。做本机真实读取与 UI 检查。权限弹窗由用户操作；蜂窝硬件、无 Wi‑Fi 机器及多种 VPN 的实际表现需另行验证。

## 实现与验收记录

- 已实现上述第三 TAB、系统信息读取、按需出口查询、信号趋势、权限入口和文本/CSV 导出。
- 当前 Mac 的独立检查实例已读到真实接口地址、IPv4/IPv6 网关、Wi‑Fi RSSI/噪声/SNR、信道、带宽、PHY、安全模式与 Tx 速率；未授权时 SSID/BSSID 显示不可用，未替用户发起授权。
- 已验证一次真实 IP.SB HTTPS 查询，返回有效 IP、ISP 与 ASN；未将实际 IP、SSID 或 BSSID 固化在仓库夹具中。该验证不代表服务在所有地区均可用，也不代表签约运营商确认。
- `LocalNetworkTests` 覆盖模型/导出/状态边界及真实本地读取，`WorkspaceTests` 增加第三 TAB 不干扰探测的验证。CLI 的 CoreWLAN 可读性可能与完整 `.app` 不同，实际界面另行检查。
- 第一版自动选系统默认/已连接 Wi-Fi 接口，显示全接口列表；周边扫描已在后续增量实现。尚无手动指定被观察 Wi-Fi 网卡、速率压测、蜂窝信号、快照回放或跨会话信号持久化。
