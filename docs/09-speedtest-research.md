# 网络测速：成熟能力接入调研与设计建议

核查日期：2026-10-30。结论：**可以包装成熟测速引擎，推荐 Cloudflare 作为首个跨平台候选，macOS `networkQuality` 作为原生对照。** 增加第四个“网络测速”TAB，以统一界面、结果解释和 CSV 历史为产品价值；不要只嵌网页，也不需要先自研吞吐测量算法。

本文保留调研时的方案与证据边界；后续开发状态见 [实现与验证](10-speedtest-implementation.md)。只读取公开资料、上游源码和本机手册，并进行了零字节端点检查；没有运行大流量测速，没有接受第三方协议或开通付费服务。

## 1. 候选能力对比

| 方案 | 可复用的能力 | 集成与条件 | 对 NetPulse 的建议 |
| --- | --- | --- | --- |
| Cloudflare `@cloudflare/speedtest` | HTTP 上传/下载、空闲与负载下时延、jitter、可选 TURN 丢包及场景参考分数 | 官方浏览器 JS/TS 引擎，MIT；公共测量端点是默认值，但引擎许可不等于节点无限使用/SLA 承诺。默认完成后回传结果；可配置关闭回传 | **首选原型**，捆绑固定版本引擎，原生界面包装；验证 WKWebView 后再宣布支持 |
| Apple `networkQuality` | 上传/下载吞吐、空闲时延、满载响应能力 RPM；支持指定接口和运行时间 | 当前 Mac 已有 `/usr/bin/networkQuality`，`-c` 输出机器可读结果，不需另装 Node 或第三方二进制；限 macOS | **原生对照/备用**，复用现有 Process 调度；字段按系统版本适配 |
| Ookla Speedtest Web SDK | 官方网络/私有节点的上下载、时延、jitter 与节点信息，自定义 UI | 官方发布的 `@ookla/speedtest-js-sdk` 明确要求购买许可；公开 npm 包不代表开源授权。CLI 的使用许可与 GUI 封装、再分发也不能画等号 | 有商务预算和明确授权后再接；不把免费 CLI 自动捆绑进产品 |
| 测速网 SpeedTest.cn SDK | 官方产品页面列出 Web、Android、iOS、Windows、macOS、Linux 等集成支持及国内运营商覆盖 | 本轮可检索到官方 SDK 页面摘要，直接页面返回 405；价格、配额、数据政策、具体 macOS 接口和发行许可尚未核实 | **国内商业候选**，需要拿到官方接入文档与报价；不能据宣传判断覆盖/准确率已验证 |
| M-Lab ndt7 | 单流上下载吞吐、时延和 TCP 诊断；JS、Go 与移动端客户端 | 参考 JS 客户端 Apache-2.0；公共基础设施可集成且不需 API key，但要求知情同意，结果含 IP/时间公开，不能要求这次不进入公开数据集 | 可选研究/对照源，默认不启用，不适合默认为本地隐私工具的测速源 |
| Fast.com / Netflix | Netflix 服务方向的上下载及空闲/负载时延 | 官方页面面向个人测量；本轮未找到可直接采用的公开稳定官方 SDK 与嵌入授权。官方也说明不用于第三方企业认证 | 保留外部浏览器对照入口；不抓网页 DOM 或提取内部 token 作为核心引擎 |
| LibreSpeed | 自托管上下载、HTTP 时延/jitter、多节点，可选遥测 | LGPL-3.0-or-later；需要自备带宽/服务器，发行时保留并满足相应许可条件；公开站点不是任意可复用的节点池 | 后续自建国内/企业节点的候选，数据流向和节点位置更可控 |
| OpenSpeedTest | 可自托管的浏览器测速 | 官方仓库 README 标注 MIT；仍需服务器、带宽和运维，不能由客户端开源推导公共节点授权 | 自建候选，可与 LibreSpeed 做小规模对比后决定 |
| iperf3 | 对指定服务器测 TCP/UDP 等吞吐；UDP 可测丢包/jitter，机器可读输出 | ESnet 官方 BSD 风格许可；要有配套服务器，不是现成免费全球测速服务；客户端/服务端版本需验证 | **后续局域网/指定节点测速**，用于把 Wi-Fi 链路和公网问题分开 |

主要依据：[Cloudflare 引擎](https://github.com/cloudflare/speedtest)、[MIT 许可](https://github.com/cloudflare/speedtest/blob/main/LICENSE)、[Apple WWDC](https://developer.apple.com/videos/play/wwdc2021/10239/)、[Ookla 官方 SDK 包](https://www.npmjs.com/package/%40ookla/speedtest-js-sdk?activeTab=versions)、[测速网 SDK](https://b.speedtest.cn/speedtest-sdk/)、[M-Lab 开发者说明](https://www.measurementlab.net/develop/)、[NDT 方法](https://www.measurementlab.net/tests/ndt/)、[Fast.com 官方说明](https://fast.com/)、[Netflix 指标解释](https://about.netflix.com/en/news/fast-com-now-measures-latency-and-upload-speed)、[LibreSpeed](https://github.com/librespeed/speedtest)、[OpenSpeedTest](https://github.com/openspeedtest/Speed-Test)、[ESnet iperf3](https://www.es.net/engineering-services/network-performance-tools/)。

上述许可为官方说明摘述，不代表已完成某种发行方式的全部协议审查。Ookla 官网 CLI/EULA 页面本轮工具访问受限，未依赖第三方转载确认其最新完整条款；SDK 的商业许可要求另通过官方 npm registry 的 README/元数据核查。

## 2. Cloudflare 的实际可接入程度

### 已核对的版本和源码

本轮读取上游 `@cloudflare/speedtest` **1.15.0**，Git commit `7183e970bda21c900e7f4bcf9c5416aa08257e27`。这些是本次快照，不是对未来最新版本的承诺。

- 默认实例化会自动开始：必须显式 `autoStart: false`，不能打开 TAB 就消耗流量。
- 默认 GET 下载 `https://speed.cloudflare.com/__down`，POST 上传 `https://speed.cloudflare.com/__up`，测量计划可配置。
- 默认 `logAimApiUrl` 指向 `__results`，完成后回传测量；本地历史优先的方案显式设 `logAimApiUrl: null`、`logMeasurementApiUrl: null`，保留版权声明。关闭结果回传不代表 Cloudflare 看不到测量请求的出口 IP，也不意味着服务端没有访问记录。
- 默认吞吐汇总使用满足时长条件样本的 P90；空闲时延默认用 P50；jitter 是相邻时延样本绝对差均值。需要保存引擎版本与聚合口径，不可包装成所有来源通用的“平均网速”。
- 默认会测下载/上传负载下的时延。丢包测量不在默认计划中，需要配置自己的 TURN 服务/临时凭证入口；不可把未测丢包显示为 0%，也不可静态内置长期 TURN 密钥。
- 提供逐阶段/变化回调、原始测量点与汇总，以及 pause/play/restart 接口。能支撑原生进度与历史，但“停止后所有请求确已中断”仍须原型验证。

源码依据：[默认配置](https://github.com/cloudflare/speedtest/blob/7183e970bda21c900e7f4bcf9c5416aa08257e27/src/config/defaultConfig.ts)、[汇总算法](https://github.com/cloudflare/speedtest/blob/7183e970bda21c900e7f4bcf9c5416aa08257e27/src/Results/MeasurementCalculations.ts)、[结果回传入口](https://github.com/cloudflare/speedtest/blob/7183e970bda21c900e7f4bcf9c5416aa08257e27/src/index.ts)、[回传载荷](https://github.com/cloudflare/speedtest/blob/7183e970bda21c900e7f4bcf9c5416aa08257e27/src/logging/logFinalResults.ts)。

### 流量不能直接照搬默认计划

对该版本默认配置逐轮相加，若所有声明轮次都执行，下载 payload 为 **969 MB**、上传为 **296.8 MB**，合计 **1,265.8 MB，约 1.27 GB**（十进制）。这是源码计划求和，不是实测实际流量；引擎可提前结束后续轮次，实际流量随链路和时长变化，另有延迟探测、协议与重传开销。

因此 NetPulse 应提供有明确 payload 预算的适配计划，例如默认 256 MB、可选较小预算；显示预计/已用流量和“流量上限内是否收敛”。预算不足时显示“受限估计/尚未收敛”，不能把测试文件传完直接当作已跑满千兆。预算只代表配置与已统计的应用数据，不能声称等于运营商计费流量的硬上限。

### 对 WKWebView 的判断

建议使用 **本地捆绑 JS + WKWebView 运行测量 + SwiftUI 展示**。这是浏览器测量库，不能仅放到 JavaScriptCore 或 Node 就认为 PerformanceResourceTiming 等浏览器能力可用；也不建议第一版把算法改写成 URLSession 后仍称为同一种 Cloudflare 测试。

本轮只发起了 `__down?bytes=0` 的小请求，收到 HTTP 200、`Content-Length: 0`、`Access-Control-Allow-Origin: *`、`Timing-Allow-Origin: *` 与 Server-Timing。这支持继续做浏览器接入原型，**不证明**本地 scheme/file origin、WKWebView PerformanceResourceTiming、上传和完整测速已经通过，也不证明中国内地各网络的节点覆盖或测速质量。

原型必须核查 WebKit 计时字段、CORS、页面来源、缓存、测量点缺失、桥接消息校验，以及停止/切 TAB 后的请求生命周期。运行时不依赖远端 JS CDN 自动升级；捆绑固定版本，不关闭 TLS 校验，不伪造来源绕过服务限制。

## 3. 为什么保留 Apple 系统测速

已读取当前 Mac 的 `man networkQuality`，没有运行测量。可用开关包括：

```text
networkQuality -c         # 机器可读 JSON
networkQuality -s -c      # 顺序上下行；默认是并行负载
networkQuality -I en0 -c  # 指定接口
networkQuality -M 30 -c   # 指定最大运行秒数
```

手册列出 `dl_throughput` / `ul_throughput`（bits/s）、`base_rtt`（ms）、`responsiveness`（RPM），顺序模式可提供分方向 RPM 与负载下请求/握手字段。字段不是跨系统版本不变的完整 schema，适配器应使用可选字段和版本测试；不能把某个缺失字段填成 0。

RPM 是负载下响应能力指标，不能简单用 `60000 / RPM` 当成可与 Ping 直接比较的网络 RTT。Cloudflare 的 HTTP 测量时延、系统 RPM、已有 ICMP RTT 与 iperf3 的 UDP 丢包/jitter 必须分别标识。Apple 的服务器配置可自定义，官方服务器示例见 [network-quality/server](https://github.com/network-quality/server)。本机工具可调用并不意味着 NetPulse 可以捆绑 Apple 二进制发到其他平台。

## 4. 其他来源的重点边界

**M-Lab**：官方允许商业/闭源客户端集成并提供无 key 的公共服务，但必须遵守 AUP、提供测量前知情说明。官方当前开发者页写明每客户端每天 40 次限流，集成场景建议不超过每天 4 次；不能把免费理解为无限批量探测。其 [隐私政策](https://www.measurementlab.net/privacy/) 明确公开数据含 IP 和时间，[开发说明](https://www.measurementlab.net/develop/) 明确公共服务不能选择某次测试不入库；自己不发送附加元数据也不能关闭服务端记录。首版不默认启用。

**Ookla**：官方 SDK 是合法集成路径，当前 npm 包为 `UNLICENSED` 且 README 要求购买许可。不能因为网上有开源封装器、自动接受 CLI 协议参数，就认为可以任意在 GUI 中再分发、商业使用或复用服务。价格及 macOS 原生接口需要供应商确认，本轮未询价。

**Fast.com**：用于 Netflix 方向的个人速度参考；官方网站与 Netflix 公告说明有上传及空闲/负载时延。本轮未查到稳定公开的官方应用 SDK 和授权说明，故推荐外部浏览器入口。不是因为“无法显示网页”，而是抓取 DOM/内部接口不适合作为稳定的数据、生命周期和授权契约。

**国内节点/自建节点**：测速网可作为有授权的国内集成候选；LibreSpeed、OpenSpeedTest 或 networkQuality 自定义服务器适合后续自建。代码免费不等于节点、流量、跨运营商带宽和运维免费。不同节点的路由、服务器瓶颈、单流/多流与采样算法会导致结果不同，不能简单宣称哪家数字更高就更准确。

**iperf3**：对有线连接的本地服务器测速，有助于区分 Wi-Fi 链路与公网；服务器自身上联、网卡和 CPU 仍可能成为瓶颈。UDP 测试需要显式目标速率和配套服务器，不应拿公共陌生服务器当无限压测目标。

## 5. 推荐的第四 TAB

“网络测速”保持独立任务，不需要复用 Ping 的目标输入。服务选择器区分“Cloudflare / 系统对照 / 后续自建”，默认不提供看似已可用的禁用来源列表。

建议首屏包括：

1. 服务/测量目标、当前接入与代理/VPN 提示、流量预算，以及“开始测速 / 停止”。所有测速按用户点击启动，不随 TAB 打开或应用启动运行。
2. 四张主要结果卡：下载 Mbps、上传 Mbps、空闲请求时延、负载时延增幅；原生系统模式另展示 RPM，缺失项保持不可用。
3. 过程区：准备 → 空闲测量 → 下载 → 上传 → 完成；实时速率曲线、阶段时延曲线、已运行时间与已统计流量。进度来自阶段与预算，不伪造严格剩余秒数。
4. 结果解释：例如“此次上传负载下请求时延明显升高”，附实际数值与方法。不在缺少丢包数据时直接复制完整游戏/会议等级；[Cloudflare AIM](https://developers.cloudflare.com/speed/aim/) 是其自身 rubric，不是业务体验的直接实测。
5. 本地历史、导出与离线查看。对比仅在相同来源、方法和配置下进行；不同来源并列展示，不求平均“综合网速”。

## 6. 与现有功能及日志的结合

- 同时最多一个大流量测速，避免多家引擎互相压低结果。
- 不静默停止用户正在运行的 Ping。若继续 Ping，应为诊断日志标记测速负载开始/结束，并在图中解释该时段；不把主动压测造成的时延/丢包误诊为平时质量。
- 测速期间不主动做周边 Wi-Fi 扫描；记录测试前后接口、地址与 Wi-Fi 信号快照。中途网络变化时标为中断/不可直接对比，不把两张网的结果混成一次。
- 新建测速独立会话目录，沿用可读 CSV：`speed-summary.csv`、`speed-samples.csv`、`diagnostics.txt`。提供方返回的 JSON 仅作为内部解析格式，不要求用户加工 JSON 日志。
- 元信息保存 provider、引擎版本、目标/节点、方法、测试模式、预算、开始/结束与终止状态、时延/吞吐聚合口径。数据行保留阶段、时间、有效样本和缺失状态；单位统一 bps → Mbps，时延 ms，流量 bytes → MB。
- 本地网络标识只作为本地诊断上下文，不拼进提供方遥测载荷。服务商仍会看到请求 IP；提供方是否收集/公开结果必须据各自政策说明。

## 7. 建议交付顺序与验收

**第一步：小范围 Cloudflare 原型。** 固定版本，关闭自动开始与额外结果上报，验证 WebKit 空闲时延/上下行/负载时延、事件桥接和真实停止。丢包不接 TURN 时明确未测。只在用户启动后做实际流量测试。

**第二步：完整原生界面与历史。** 第四 TAB、预算与中断、曲线、CSV 导出/离线查看；记录 Wi-Fi/接口与 Ping 负载区间。把流量受限未收敛、失败、网络变化、缺失字段等作为正常状态测试。

**第三步：系统对照适配器。** `networkQuality` 复用现有进程管理，保留原始口径；不把它的速率/RPM与 Cloudflare 数据合并。

**之后再按价值选择：** 国内商业 SDK / 自建公网节点，或 iperf3 局域网模式。第一版不同时封装八种服务。

验收至少包含：有线与 Wi-Fi、小/大带宽、VPN/代理、不同系统版本、上传失败/超时、终止后无遗留流量、预算统计和中途切网、与官方网页在同一网络与相近时间分开测试对照。容许由方法和测量环境造成的差异，不能要求结果逐位一致。

当前证据边界：本轮完成官方资料及部分源码核查、本机命令能力核查、零字节下载端点检查；没有执行完整测速、没有验证 WebKit 运行，也没有实测服务间的准确率与国内节点质量。上述为调研阶段证据；后续已接入第四 TAB，运行验证与未验证项目见 [实现与验证](10-speedtest-implementation.md)。
