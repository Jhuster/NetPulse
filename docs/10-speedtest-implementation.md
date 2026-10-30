# 网络测速：实现与验证

实现日期：2026-10-30。第四个 TAB 提供 Cloudflare 测速和 macOS 系统对照，按用户点击运行一次，不自动循环。

## 使用流程

选择测量服务 → Cloudflare 选择 64 / 256 MB 测试数据预算 → 开始测速 → 查看空闲时延、下载、上传、负载时延与请求吞吐量散点 → 自动保存会话目录。可停止，或切换 TAB 让测试继续运行。再次开始创建新日志，不覆盖上一份。最近 20 次历史可点击离线查看，也可导入外部会话目录或其中的 CSV 文件。

Cloudflare 默认 64 MB 档最大计划负载为 62.4 MB；256 MB 档最大计划负载为 232.4 MB。引擎可能提前结束，预算守卫在每次请求前累计调度字节，包含重试。零字节时延请求不增加负载字节，仍受最多 512 次请求限制；单请求最长 20 秒，吞吐引擎单次测量上限 10 秒，整个会话最长 180 秒。预算不包含 HTTP/TLS 开销、重传和其他应用流量，不能作为计费流量统计。高带宽网络可能需要更多负载才能充分收敛。

系统对照执行 `/usr/bin/networkQuality -s -M 30 -c`，顺序测上下行，应用另有 45 秒保护。系统工具无法按字节限流，界面明确提示无流量上限；仅最终结果可用，没有伪造过程曲线。系统不同版本可能不返回全部字段，缺失值留空。

## 测量口径

- Cloudflare 使用正式 npm 发布的 `@cloudflare/speedtest 1.15.0`，保留 MIT 许可与下载完整性摘要。`dist/speedtest.global.js` 仅将 ESM 的唯一终端 export 替换为 `window.CloudflareSpeedTest`，以在本地 WebKit 页面中加载；上游测量算法未修改。
- WebKit 使用临时数据存储，本地资源随应用打包，无需 Node/npm 环境、远程脚本或网页 DOM 抓取。自动开始、附加 AIM / 测量结果回传均关闭。CSP 与 fetch 允许列表限制请求到 `https://speed.cloudflare.com/__down` 和 `/__up`。
- 下载/上传为引擎吞吐统计，默认第 90 百分位，内部及 CSV 用 bit/s，UI 转 Mbps（除以 1,000,000）。散点是各次请求的吞吐量，不是网卡瞬时速率。空闲时延默认第 50 百分位，抖动使用引擎原始口径，均以 ms 表示。
- HTTP 时延与 ICMP Ping 的 RTT 方法不同；负载时延分别显示下载和上传过程的结果，以及相对空闲增幅。系统的 RPM 单独展示，不用 `60000 / RPM` 转成 Ping RTT。
- 未接入 TURN 丢包测量，不生成游戏/视频会议等级；丢包明确未测。有效统计不足、服务不可达和超时可显示部分结果，不能当完整成功。

## 生命周期与并行工作

测速 Store 属于顶层工作区，WebKit 承载视图在根视图保留，切换 TAB 不销毁测量。点击停止会调用引擎 pause、取消包含响应体传输阶段的 AbortController，并销毁 WebKit 页面。系统进程先 terminate，仍未退出则在 2 秒时 SIGKILL；前一个引擎回收完成前不允许启动下一个，关闭应用也等待回收。会话 UUID 校验拦截旧回调，防止旧结果污染新会话。

测速不会自动暂停用户的 Ping；Ping 的 diagnostics.txt 标记 load_start / load_end，提示负载影响。测速期间不允许发起主动周边 Wi-Fi 扫描，扫描未结束时不启动测速。系统路径监控与每 3 秒的本地配置快照用于检测路径、网关、地址或可读 Wi-Fi 身份变化；发现后结束本次会话，标记 network_changed。采样无法保证发现短于采样间隔的切换，也不能在无权限时识别被系统隐藏的 AP 身份。

## 日志规范

默认目录：`~/Library/Logs/NetPulse/Speed/<UUID>/`。

| 文件 | 内容 |
| --- | --- |
| summary.csv | `#` 元信息（会话、版本、服务、端点、聚合、预算、开始/结束、状态、单位）；一行汇总统计 |
| samples.csv | `id,timestamp,kind,bps,duration_ms`；请求吞吐采样，时间为 UTC ISO-8601 毫秒 |
| network-context.txt | 开始前本地网络快照；仅本地保存 |
| network-last-observed.txt | 最新一次已观察到的本地快照及其采样时间，可能早于停止时刻 |

状态包含 running、completed、stopped、failed、timed_out、network_changed。running 的导入记录表示未正常收尾，不推断已完成。缺失值为空，0 保留为实测值。CSV 加工可用 `pandas.read_csv(path, comment="#")`。

汇总与采样文件分别以原子替换写入，每次更新保存；应用崩溃可能留下最近一次有效的部分记录，两份文件不是数据库事务快照。导入验证类型/版本/会话、有限非负数、样本唯一性和大小上限，失败不覆盖当前结果。导出仅复制上述已知日志文件，避免复制导入目录内无关文件。日志可能包含本地 IP 和 Wi-Fi 标识，分享前可自行检查。

## 已执行验证

- 完整离线/loopback 回归：Ping、路径诊断、MMDB、本机网络、周边 Wi-Fi，以及新增测速计划预算、系统字段/单位/缺失/错误、CSV 往返与损坏、停止保留部分结果、旧回调隔离、导入不自动测速。
- WebKit 小流量测试：512 KB 计划负载，成功返回空闲时延、下载和上传。一轮曾遇到 Cloudflare 负载时延请求失败，重试成功；服务/网络失败会显示失败并保留部分结果，不做后台自动重测。
- 原生界面一次默认 64 MB 档：21 秒完成、调度 62.4 MB 负载；切换 TAB 后继续运行；历史点击还原统计与图表。截图见 README，仅代表当时网络与服务节点。
- 原生停止测试：测量过程中停止后 WebKit 页面完成销毁。尚未通过抓包量化停止后的在途字节。
- 构建打包 WebKit 和本地引擎资源，ad-hoc 签名校验通过。

尚未执行：系统工具真实满载测试、256 MB 档真实测试、真实中途切网、跨系统版本、不同 VPN/代理、有线/Wi-Fi 多环境对照、与官方网页的测量准确率比较。这些属于后续验收，不由单次接通测试推导。

手动小流量 WebKit 验证（不在普通回归中自动联网）：

```sh
swiftc -swift-version 5 -module-cache-path .build/module-cache -parse-as-library src/NetPulse/SpeedWebEngine.swift tests/SpeedWebSmoke.swift -o .build/speed-web-smoke -framework AppKit -framework SwiftUI -framework WebKit
.build/speed-web-smoke
.build/speed-web-smoke --cancel
```

方案取舍与官方来源见 [接入调研](09-speedtest-research.md)。
