# CSV 日志规范 v2

每次新建会话，在 `~/Library/Logs/NetPulse/<session-id>/` 下创建 `session.csv` 和 `diagnostics.txt`。暂停/继续沿用当前文件，换目标必须新建会话。CSV 保存统计窗口，诊断文本保存事件、逐包结果和系统 Ping 输出，不再产生 JSON。保留旧 JSONL 只读导入兼容。

## 示例

```csv
# NetPulse-Version: 0.1.0
# Log-Version: 2
# Session-ID: example
# Target: example.com
# Started-At: 2026-10-29T06:00:00.000Z
# Window-Seconds: 5
timestamp,loss_pct,rtt_avg_ms,jitter_ms,sent,received,errors,window_status,rtt_status,jitter_status,rtt_min_ms,rtt_max_ms,window_index
2026-10-29T06:00:00.000Z,0.0,23.5,2.1,5,5,0,complete,ok,ok,21.0,26.0,0
2026-10-29T06:00:05.000Z,100.0,,,5,0,0,complete,all_lost,insufficient_pairs,,,1
```

文件为 UTF-8，逗号分隔，点号小数。时间为 UTC ISO 8601，含毫秒。数值最多保留六位小数并去除尾零，避免浮点尾数影响阅读；CSV 回放误差不超过 0.000001 ms 或百分点。

- `#` 开头为元信息，包含版本、目标、会话、开始时间、系统、间隔、统计口径与缺失值说明。它是 CSV 扩展约定。
- 每个窗口一行，`window_index` 在会话内唯一。暂停/导出时最后一行可为 partial；同窗恢复时原位替换尾行，不追加重复窗口。
- `sent` 为已完成的探测次数；系统/DNS 错误记 `errors`。丢包分母为 `sent-errors`，避免把工具异常计为网络丢包。
- `loss_pct`、RTT、jitter 均为数值列；缺失留空。零是有效测量值。
- `rtt_status`：`ok`、`all_lost`、`probe_error`；`jitter_status`：`ok`、`insufficient_pairs`。
- `window_status`：`complete`（5 条完成记录）或 `partial`；错误数量另列，不代表完整窗口一定网络正常。
- 窗口终了且在途探测已结束才写入；暂停和导出会保存已完成部分。异常退出可能丢失尚未汇总的窗口；诊断文件中的 probe_start 可辅助排查，CSV 不补造数据。
- 诊断文本不参与 CSV 回放；仅凭窗口统计不能还原逐包 RTT。CSV 还原图表、窗口样本数和累计统计，原始输出从诊断文件读取。

## 加工示例

```python
import pandas as pd
frame = pd.read_csv("session.csv", comment="#", parse_dates=["timestamp"],
                    dtype={"loss_pct": "Float64", "rtt_avg_ms": "Float64", "jitter_ms": "Float64"})
```

Excel 可直接打开，但元信息会显示为表格上方的行；做筛选和公式时应从列名行开始选取区域。

## 导入与导出

导入单个 CSV 或含 `session.csv` 的会话目录；导出 `.netpulse` 目录包含 CSV 和诊断文件。未知版本/不正确列名拒绝导入；重复索引、损坏行、越界值报告并跳过；没有结尾换行提示可能截断。CSV 导入上限 50 MB，不限制诊断文件大小但不读入内存。

主 CSV 单文件持续追加，无分卷；诊断文本也持续写入，不自动删除。磁盘配额和大文件流式查询仍为待完善事项。
