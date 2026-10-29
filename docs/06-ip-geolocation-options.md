# IP 地理归属接入方案

核查日期：2026-10-29。本文讨论逐跳公网 IP 的国家/省份归属，不是获取设备 GPS 位置。已接入本地 MMDB 自动查询，并保留精确 IP CSV 作为覆盖层。在线地理服务尚未接入；未下载完整生产数据库、未查询用户路径地址。

## 本次实现

- 路径页提供“下载并启用 / 管理归属数据库”入口，点击后自动从 DB-IP 官方页面识别最新 MMDB 下载地址，不依赖本机月份猜测版本。展示数据来源、约百 MB 体积及 CC BY 4.0 许可，保留署名。下载仅允许官方 HTTPS 地址，支持进度、取消、超时及 512 MB 上限；自动解压后校验安装。设置页保留 `.mmdb` / `.mmdb.gz` 文件导入作为备用。
- 支持 DB-IP City Lite 与 GeoIP / GeoLite City、Country schema；未实现 IP2Location BIN 或范围 CSV 读取。国家/省份优先取中文名称，回退英文；国家还可按 ISO 代码本地化，省份不使用城市代填。
- 数据库导入在后台进行，保存到 `~/Library/Application Support/NetPulse/GeoIP/geolocation.mmdb`；重启自动加载。先校验后原子替换，失败保留旧库。512 MB 文件及解压大小上限；解码另限制深度、值数量与展开字节，损坏记录显示未知并提示。
- 节点出现后后台补齐归属；本地精确 IP CSV 覆盖优先。来源与构建日期随逐跳结果保存，不改变日志列。新建会话隔离异步结果，历史回放保持日志快照。
- 来源署名显示在路径页及设置页；私网/共享/保留地址不查公网归属。
- 已通过 MaxMind 官方小型测试库及自建格式夹具验证，覆盖 24/28/32 位树、IPv6 树中的 IPv4 地址、中文/英文回退、指针与长度、异常输入、gzip、持久化、替换失败、覆盖优先级与回放隔离。另已完成一次真实官方下载 → 解压校验 → 完整库安装 → 公网 IP 查询，数据为 DBIP-City-Lite，构建日期 2026-10-01。该测试仅验证链路和可读性，不代表真实节点归属准确率验收。

实现参考：[MMDB v2 规范](https://maxmind.github.io/MaxMind-DB/)、[DB-IP MMDB schema](https://db-ip.com/db/format/ip-to-city-lite/mmdb.html)。

## 建议

已采用 **本地 MMDB，按需安装/选择文件**，不要求用户为每条路径手工准备归属表。推荐首选 DB-IP Lite City MMDB；IP2Location LITE DB3 可作为后续候选，但当前未支持其 BIN 格式。还需要用常见的国内、跨境与云网络节点验证覆盖和省份结果，不宣称某个库必然更准确。

| 候选 | 官方能确认的字段/条件 | 对本工具的适合程度 |
| --- | --- | --- |
| DB-IP Lite City | 国家、州/省、城市；提供 CSV/MMDB；每月更新；CC BY 4.0，要求注明 DB-IP 来源，Lite 覆盖和准确性低于商业版 | 已实现 MMDB 离线查询和来源展示，生产数据覆盖仍待实测 |
| IP2Location LITE DB3 | 国家、region/state、城市；IP 起止段；CSV/BIN；官方说明免费使用需署名 | 很适合国家/省份；可用紧凑 BIN 或建立范围索引，需新增适配器 |
| IPinfo Lite | 国家、大洲、ASN 和网络组织；免费 API/下载数据 | 可补国家/网络归属，缺少省份，不能单独满足当前需求 |
| GeoLite2 City | 国家、省级细分与城市等；需账户与 license key 下载，需遵守来源/使用及再分发条件；有些 IP 只有国家 | 已支持 MMDB schema；下载条件由用户在官方页面核查，不随应用分发 |
| 在线地理 API | 逐个公网 IP 请求对应服务商，接口与计划字段不同 | 可以做可选增强，需要 HTTPS、查询开关、缓存与限流；不应影响主扫描 |

来源：[DB-IP Lite](https://db-ip.com/db/lite.php)、[DB-IP City 字段与下载](https://db-ip.com/db/download/ip-to-city-lite)、[IP2Location DB3](https://lite.ip2location.com/database/db3-ip-country-region-city)、[IPinfo Lite API](https://ipinfo.io/developers/lite-api)、[GeoLite 文档](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data/)、[MaxMind 数据字段](https://dev.maxmind.com/geoip/docs/databases/city-and-country/)。以上是官方能力和条款说明的摘述，不是质量测评。

## 体积与使用体验

核查时 DB-IP City Lite 页面列出的 MMDB 为约 121 MB，CSV 为约 661 MB；IP2Location DB3 的 IPv4 BIN 约 46 MB、CSV 约 210 MB。这些数字是当前发布版快照，不是固定包大小。建议按需安装，优先二进制索引，不把完整 CSV 逐行塞进当前应用内存。

当前应用支持 MMDB 及 `ip,country,province` 精确 IP 覆盖表。**不能把供应商范围 CSV 或 IP2Location BIN 当作归属覆盖表导入**；需要各自的格式适配，目前未实现。

DB-IP City MMDB 页面标注支持中文等语言，CSV 标注英文；实际字段缺失或名称语言仍需读取后确认。国家可按 ISO 代码本地化，省份应优先采用数据源名称，不凭空补齐。

## 在线接口的具体边界

[IP-API 免费接口](https://ip-api.com/docs/api:json) 支持 country / regionName，但官方文档写明免费接口不支持 HTTPS、每 IP 每分钟 45 次请求且不允许商业使用。因此不建议把它作为应用默认在线数据源；需要 HTTPS/商业计划的接口或其他适合发行的供应商。不能为了接口临时可用而放宽整个应用的网络安全设置。

在线方案会将待查公网 IP 发送给供应商，应由用户明确启用，界面说明供应商；不发送私网、共享或演示保留地址。密钥不随应用公开分发，可采用用户配置或受控后端。按新 IP 去重查询，缓存按数据源/版本管理，遇限流退避，查询失败仍展示路径结果。

## 展示与日志

- 节点显示“国家 · 省份”，详情标注数据源与版本/更新时间；缺失字段显示未知。
- 私网/共享地址继续显示不适用，不能将本机所在城市套用到内网节点。
- 路径 CSV 保存当时查询结果与来源；离线回放不重新查询，避免历史现场被新版库改写。
- [MaxMind 官方说明](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data/) 指出 IP 定位本质上不精确，有些地址缺省份/城市。结果应标为 **IP 地理归属参考**，不是路由器、机房或光纤的实测物理位置。

## 后续交付顺序

1. 用完整 DB-IP Lite City 数据库对更多真实节点做覆盖和性能验证。
2. 根据实测决定是否增加其他格式、更新提醒和覆盖表持久化；当前更新由用户点击发起，不会静默下载。
3. 有明确收益时再接可选在线增强，不让地图或外部查询阻塞探测。
