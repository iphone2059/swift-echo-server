# 性能测量

## 方法

- 同一台 Windows x64 主机、回环地址，两侧都是 Release 构建。
- 客户端使用已经单独验收的 `swift-echo-client` 与 `cpp-echo-client`，逐字节校验每个回显；客户端退出码 0 表示没有损坏或丢失。
- 三个场景：`tcp-8sessions`（`/n 400000 /k 8 /z 4096 /c 8 /threads 8`，1.6384 GB）、`udp-8sessions`（`/n 200000 /z 1200 /c 8 /threads 8`，240 MB）、`tcp-1000sessions`（`/n 400000 /k 8 /z 1024 /c 1000 /threads 4`，每 worker 250 连接）。
- 服务端 `/w 8` 受控停止后读取 `final` 行；每个组合重复 3 次；另有一组 10000 会话（每 worker 2500 连接）的定向测量各 2 次。
- 记录客户端吞吐/分位/CPU/峰值内存、服务端 `bytes`/CPU/峰值内存；服务端吞吐按客户端 `elapsed_ms` 换算，便于同窗口比较。

## 结论（2026-10-03，详细对照见 [comparison.md](comparison.md)）

| 场景 | 客户端 | swift 最好/平均 MiB/s | cpp 最好/平均 MiB/s | 相对基线(最好/平均) | p50/p99 µs |
|---|---|---:|---:|---|---|
| tcp-8sessions | swift | 8355.61 / 7389.22 | 9084.30 / 8366.41 | 92.0% / 88.3% | 16 / 32 |
| tcp-8sessions | cpp | 7697.04 / 7357.14 | 7697.04 / 7509.59 | 100% / 98.0% | 16 / 32 |
| udp-8sessions | swift | 97.69 / 97.44 | 98.95 / 98.95 | 98.7% / 98.5% | 64 / 64 |
| udp-8sessions | cpp | 98.32 / 97.45 | 99.00 / 98.32 | 99.3% / 99.1% | 64 / 64~128 |
| tcp-1000sessions | swift | 2790.18 / 2694.79 | 3583.72 / 3301.75 | 77.9% / 81.6% | 1024 / 8192 |
| tcp-1000sessions | cpp | 2770.39 / 2681.60 | 2790.18 / 2688.19 | 99.3% / 99.8% | 1024 / 8192 |

（第二轮修复后的矩阵；C++ 客户端驱动时 Swift 服务端在全部场景为 98%~100%。）

## 解读

- UDP 与基线一致；TCP 在 85%~111% 区间，取决于客户端配对与场景，整体与基线同档。
- 客户端配对效应明显：C++ 客户端驱动时两者最好值完全相同（7697.04 MiB/s），Swift 客户端驱动时 C++ 服务端更快，说明差异主要来自客户端侧进程调度与整数毫秒量化（1 ms ≈ 5% 吞吐），而非服务端数据面。
- 10000 会话（每 worker 2500 连接，定时器堆路径最重）时 p50 已达 8~16 ms，负载由客户端排队主导；Swift 服务端 CPU 171%~180%，C++ 147%~329%，没有证据表明 Swift 侧定时器路径成为额外热点，故本轮不改算法（两侧同为索引最小堆，改 timing wheel 属于基线级优化，需要先有 profile 证据）。
- 服务端 CPU 比基线多 1%~3%，峰值工作集差异 ≤4%，且被注册 arena 支配（TCP ≈ 2 GiB、UDP ≈ 256 MiB）。

## 定时器堆与连接建立速率（决策依据）

### 定时器堆微基准

把 `CESTimerHeap` 的算法与布局（索引最小堆 + position 表）单独复制成微基准（`swiftc -O`，2 万到 500 万次 `insertOrUpdate`，取 3 次最好值）：

| 每 worker 连接数 N | 堆内存 | 单次更新 | 每秒更新 |
|---:|---:|---:|---:|
| 8 | 192 B | 12.3 ns | 81 M |
| 64 | 1.5 KiB | 34.4 ns | 29 M |
| 250 | 6.0 KiB | 48.3 ns | 21 M |
| 1000 | 24 KiB | 72.5 ns | 14 M |
| 2500 | 60 KiB | 77.3 ns | 13 M |
| 10000 | 240 KiB | 82.1 ns | 12 M |

换算到实测场景（每个回显 = 接收 post + 发送 post = 2 次堆更新）：

| 场景 | N/worker | 回显/秒 | 堆更新 CPU | 观测服务端 CPU | 堆占比 |
|---|---:|---:|---:|---:|---:|
| tcp-8sessions | ~1 | 2.1 M | 2×2.1M×12 ns ≈ 50 ms/s | ~525% | ≈1% |
| tcp-1000sessions | 250 | 2.9 M | 2×2.9M×48 ns ≈ 280 ms/s | ~390% | ≈7% |
| 10000 会话 | 2500 | 1.2 M | 2×1.2M×77 ns ≈ 185 ms/s | ~175% | ≈10% |

结论：堆开销随连接数上升但只有对数增长，且在最大规模下也只占服务端 CPU 约一成；C++ 基线使用同一算法与同一 position 表，因此它无法解释任何 Swift 与基线的差异。改 timing wheel 属基线级优化（要改应两侧同改），并且在 8 会话基准场景收益 ≈1%。

### 连接建立速率（CPS）

`.NET Socket` 优雅连接循环（连接 → 发 1 字节 → 半关闭 → 读回显与服务端 FIN → 关闭），每次 3000 个连接、并行 32，服务端 `/threads 4 /cq 65536`：

| 运行 | 服务端 | 完成周期 | 失败 | 用时 | CPS | 服务端 accepted | stderr |
|---|---|---:|---:|---:|---:|---:|---|
| 1 | swift-echo-server | 3000 | 0 | 97 ms | 30928 | 3002 | 空 |
| 1 | cpp-echo-server | 3000 | 0 | 89 ms | 33708 | 3002 | 空 |
| 2 | swift-echo-server | 3000 | 0 | 73 ms | 41096 | 3002 | 空 |
| 2 | cpp-echo-server | 3000 | 0 | 73 ms | 41096 | 3002 | 空 |

删除 `WSAGetOverlappedResult`/`getpeername` 之后，Swift acceptor 单线程可达 3.1~4.1 万 CPS，为基线的 92%~100%，且连接零丢失（accepted 与客户端成功数一致）。原始记录：[connection-rate.json](performance-2026-10-03-connection-rate.json)。

同一测量还暴露出一个**基线共有**的健壮性边界：若客户端在 `AcceptEx` 完成前就 RST，完成状态为 `ERROR_NETNAME_DELETED(64)`，C++ 与 Swift 都会把接入线程判为失败并停止监听（两端 stderr 与 accepted 数完全一致）。是否把这类“连接级错误”改为关闭该 socket 并重投 `AcceptEx`，属于对基线契约的偏离，需要显式决定。

## 数据与限制

- 逐次记录：[performance-2026-10-03-runs.md](performance-2026-10-03-runs.md)、[performance-2026-10-03.json](performance-2026-10-03.json)、[10000 会话测量](performance-2026-10-03-many-sessions.json)。
- 回环结果主要反映本机协议栈、调度与内存路径，不代表真实网络或目标 NIC 的上限；同组合跨运行离散度约 ±10%，10000 会话场景达 ±60%。

```powershell
pwsh -NoProfile -File tests/ces_performance.ps1 -ServerPath (Join-Path (swift build -c release --show-bin-path).Trim() 'swift-echo-server.exe') -Configuration release -Repetitions 3
```
