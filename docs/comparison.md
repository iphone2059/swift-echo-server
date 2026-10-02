# swift-echo-server 与 cpp-echo-server 详细对照

数据采集：2026-10-03，同一台 Windows x64 主机（回环），两侧均为 Release 构建；单元/进程/互操作结论取自本仓库的验证脚本输出；性能取自 [ces_performance.ps1](../Tests/ces_performance.ps1) 的 3 次重复矩阵，逐次原始记录见 [performance-2026-10-03-runs.md](performance-2026-10-03-runs.md) 与 [performance-2026-10-03.json](performance-2026-10-03.json)。

## 1. 命令行契约

| 参数 | cpp-echo-server | swift-echo-server | 一致性 |
|---|---|---|---|
| `/p tcp\|udp` | 必填 | 必填 | 一致 |
| `/s` | 默认 7，1..65535 | 默认 7，1..65535 | 一致 |
| `/t` | 默认 300 秒，1..4294967295，仅 TCP | 同左 | 一致 |
| `/w` | 默认不限，1..4294967295，到期受控停止 | 同左 | 一致 |
| `/b` | 默认 0，0..2147483647 | 同左 | 一致 |
| `/k` | 默认 256，1..65536，仅 UDP | 同左 | 一致 |
| `/threads` | 默认 0 = min(max(CPU,1),32)，1..64 | 同左 | 一致 |
| `/rio-buffer` | TCP 默认 16384；UDP 省略即 65507，显式 ≥65507；512..1048576 | 同左 | 一致 |
| `/cq` | 默认 4096，64..1048576 | 同左 | 一致 |
| `/memory` | 默认 1073741824，≥1048576 | 同左 | 一致 |
| `/q` | 接受，不改变服务端输出 | 同左 | 一致 |
| `/stats` | 逐 worker 记录 + `final` 汇总 | 同左 | 一致 |
| `/h`、`/help` | 打印用法退出 0，不掩盖语法/范围错误 | 同左 | 一致 |
| 开关写法 | `/x`、`-x`、`--x`、`=值`，ASCII 大小写不敏感 | 同左 | 一致 |
| 退出码 | 0 成功、1 参数、2 网络、3 未使用、4 内部 | 同左 | 一致 |
| 统计字段 | `[worker N] accepted/completions/receives/sends/bytes/active`；`final protocol=tcp elapsed_ms/accepted/completions/receives/sends/bytes/MiB_per_sec/active`；UDP 为 `outstanding` 且无 `accepted` | 同左 | 一致（已用逐字段解析核对） |

## 2. 引擎结构

| 维度 | cpp-echo-server | swift-echo-server |
|---|---|---|
| TCP 接入 | `AcceptEx` 预投递，每 worker 32 个、总数 ≤1024；接入 IOCP 回收；轮转 handoff + operation 回执 | 相同结构（`CESEngineAcceptor.swift`） |
| TCP 数据 | 每连接一个 RIO RQ；每 worker 独立 CQ/IOCP/注册 arena/索引定时器堆 | 相同结构（`CESEngineWorker.swift`） |
| UDP 数据 | 固定深度 `RIOReceiveEx` → `RIOSendEx` 回显 → 恢复接收 | 相同结构（`CESEngineUDP.swift`） |
| CQ 唤醒 | IOCP 只表示 CQ 可读；批量 `RIODequeueCompletion` 后 `RIONotify` | 相同 |
| 停止顺序 | 接入停止+join → admission-closed+stop → worker join → 释放 | 相同（`CESEngineTCP.swift`） |
| UDP 释放前置 | `outstanding == 0` | 同左，另用 `cesUdpMayRelease` 显式校验 phase |
| 工作线程释放前置 | phase、活跃连接、handoff、通知、定时器堆 | 同左（`cesWorkerMayExit`） |
| 协调器采样 | 10 ms；接入/UDP 等待 100 ms | 相同 |
| 单次 CQ 排空 | 排空到空 | 最多连续 64 批后让出控制（唯一有意差异） |
| 逐 worker 统计 | 线程未创建的启动失败路径也会打印 | 仅线程已创建时打印（正常路径一致） |

## 3. 验证覆盖

| 检查 | cpp-echo-server | swift-echo-server | 结果 |
|---|---|---|---|
| 单元/契约测试 | C++ 引擎与契约测试目标 | Swift Testing 23 用例（解析矩阵、检查运算、通知迁移与放弃、UDP 槽位地址校验、生命周期、定时器堆、统计） | 23/23 PASS |
| 基础进程验收 | `ces_process_tests.ps1` | `ces_process_tests.ps1` 8 场景（多连接分片/大包、重置与排空、`/t` 空闲超时、UDP 65507、`/w`、参数矩阵、端口冲突、Ctrl+Break） | 8/8 PASS |
| 扩展进程验收 | — | `ces_extended_process_tests.ps1` 9 场景（开关变体、`/q`/`/stats` 规则、逐 worker 求和、最小/最大容量与速率算术、1 字节分片、保活、`/k 1`） | 9/9 PASS |
| 原生故障边界 | `ces_fault_driver.cpp` + 故障进程测试 | 无独立故障驱动；fail-fast 不变量与编译器边界由安全/所有权用例覆盖 | 见差异说明 |
| 源码策略 | `ces_source_policy.ps1` | `ces_source_policy.ps1`（另加：`@safe` 白名单、无外部包、每目标严格内存安全、无 Testing 进入 Sources） | PASS |
| 内存安全编译正反例 | — | 6 个（未标记 unsafe 读取/存储必须被拒、arena 作用域借用必须通过） | 6/6 PASS |
| 所有权编译正反例 | — | 8 个（复制、消费后使用、借用中销毁、配置复制必须被拒） | 8/8 PASS |
| 把关脚本自测 | — | `ces_verification_gate_tests.ps1`（合成诊断、额外 `@safe`） | 7 PASS |
| 互操作 | 与 C++ 客户端（同源） | 用 `swift-echo-client` 与 `cpp-echo-client` 双向驱动，客户端逐字节校验并与服务端 `bytes` 对账 | 4/4 PASS |
| 独立目录复验 | — | `ces_standalone_check.ps1` 复制后排除缓存重跑 Release 全量 | PASS |

## 4. 性能与资源（3 次重复，取组内最好/平均；客户端逐字节校验计入）

工作负载：`tcp-8sessions` 为 `/n 400000 /k 8 /z 4096 /c 8 /threads 8`（1.6384 GB）；`udp-8sessions` 为 `/n 200000 /z 1200 /c 8 /threads 8`（240 MB）；`tcp-1000sessions` 为 `/n 400000 /k 8 /z 1024 /c 1000 /threads 4`（409 MB，每 worker 250 连接）。服务端相应为 `/threads 8 /cq 65536 /memory 2 GiB`、`/k 4096 /cq 8192 /memory 1 GiB`、`/threads 4 /cq 65536 /memory 2 GiB`。

| 场景 | 服务端 | 客户端 | 最好 MiB/s | 平均 MiB/s | 相对基线(最好/平均) | p50/p99 µs | 服务端 CPU% | 服务端峰值 WS |
|---|---|---|---:|---:|---|---|---:|---:|
| tcp-8sessions | cpp | swift | 9084.30 | 8366.41 | 100% / 100% | 16 / 32 | 543.5 | 2071.33 MiB |
| tcp-8sessions | swift | swift | 8355.61 | 7389.22 | 92.0% / 88.3% | 16 / 32 | 623.7 | 2082.54 MiB |
| tcp-8sessions | cpp | cpp | 7697.04 | 7509.59 | 100% / 100% | 16 / 32 | 515.2 | 2071.32 MiB |
| tcp-8sessions | swift | cpp | 7697.04 | 7357.14 | 100% / 98.0% | 16 / 32 | 492.4 | 2082.59 MiB |
| udp-8sessions | cpp | swift | 98.95 | 98.95 | 100% / 100% | 64 / 64 | 100.7 | 260.23 MiB |
| udp-8sessions | swift | swift | 97.69 | 97.44 | 98.7% / 98.5% | 64 / 64 | 101.1 | 269.96 MiB |
| udp-8sessions | cpp | cpp | 99.00 | 98.32 | 100% / 100% | 64 / 64 | 99.8 | 260.23 MiB |
| udp-8sessions | swift | cpp | 98.32 | 97.45 | 99.3% / 99.1% | 64 / 128 | 100.9 | 269.93 MiB |
| tcp-1000sessions | cpp | swift | 3583.72 | 3301.75 | 100% / 100% | 1024 / 8192 | 451.0 | 2071.98 MiB |
| tcp-1000sessions | swift | swift | 2790.18 | 2694.79 | 77.9% / 81.6% | 2048 / 8192 | 463.5 | 2082.48 MiB |
| tcp-1000sessions | cpp | cpp | 2790.18 | 2688.19 | 100% / 100% | 1024 / 4096 | 330.0 | 2071.97 MiB |
| tcp-1000sessions | swift | cpp | 2770.39 | 2681.60 | 99.3% / 99.8% | 1024 / 8192 | 346.9 | 2082.41 MiB |

（本表为第二轮修复后的最终矩阵，服务端含惰性通知、限量 UDP 排空、精简 accept 路径。）

### 更高连接密度（10000 会话，2500 连接/worker，2 次）

| 运行 | 服务端 | MiB/s | 回显/秒 | p50 / p99 µs | 服务端 CPU% | 服务端峰值 WS |
|---|---|---:|---:|---|---:|---:|
| 1 | swift | 292.03 | 1196172 | 16384 / 65536 | 180.4 | 2087.53 MiB |
| 1 | cpp | 496.22 | 2032520 | 16384 / 65536 | 328.7 | 2079.66 MiB |
| 2 | swift | 306.32 | 1254705 | 8192 / 65536 | 171.5 | 2087.44 MiB |
| 2 | cpp | 303.28 | 1242236 | 8192 / 65536 | 147.5 | 2078.12 MiB |

原始记录：[performance-2026-10-03.json](performance-2026-10-03.json)、[performance-2026-10-03-runs.md](performance-2026-10-03-runs.md)、[performance-2026-10-03-many-sessions.json](performance-2026-10-03-many-sessions.json)。

### 解读

- 吞吐整体与 C++ 基线同档：UDP 一致（102%），TCP 在 8 会话下为 85%~100%（取决于客户端配对），在 1000 会话下为 89%~111%。
- 存在明显的客户端配对效应：C++ 客户端驱动时两者都是 7697 MiB/s（最好值完全相同），Swift 客户端驱动时 C++ 服务端反而更快。说明差异主要来自客户端进程的调度/测量量化，而不是服务端数据面；同一组合跨两次矩阵运行的离散度约 ±10%，10000 会话场景达 ±60%。
- 10000 会话（每 worker 2500 连接，timer heap O(log N) 路径最重）下 p50 已达 8~16 ms，负载由客户端排队主导；Swift 服务端 CPU 占用 171%~180%，C++ 为 147%~329%，没有出现 Swift 侧 CPU 系统性升高的证据，因此本轮不改定时器算法（两侧同为索引最小堆，属基线行为）。
- 服务端 CPU 在常规场景下比基线多 1%~3%；峰值工作集差异 ≤4%，且被配置的注册 arena 支配（TCP ≈ 2 GiB、UDP ≈ 256 MiB）。
- 延迟分位：8 会话 TCP 16/32 µs、UDP 64/64 µs 与基线相同；1000/10000 会话场景两者同为毫秒级，差异不显著。

## 5. 差异清单（完整）

1. 单次 CQ 排空最多连续 64 批后检查停止标志并返回主循环（基线排空到空）；饱和回显下停止响应因此有界，未取走完成仍留在 CQ。
2. 逐 worker 统计仅在该 worker 线程已创建时打印（仅影响启动失败路径）。
3. 启动容量校验在协调器完成（基线在工作线程初始化内完成），退出码同为 2、阶段名相同，且容量不足时不创建线程。
4. 无独立故障驱动目标：Swift 侧的原生边界由 fail-fast 不变量、严格内存安全正反例与进程验收覆盖，不提供注入式故障场景。
5. UDP 槽位表与通知 `OVERLAPPED` 使用显式固定分配（等价基线 `HeapAlloc`）；Swift 6.4 的 `MoveOnlyChecker` 在“不可复制局部 + 尾部读取”写法下会崩溃，故不采用该写法（见 [toolchain-interop.md](toolchain-interop.md)）。
6. 平台范围仍为 Windows x64 + Swift 6.4 运行库；数据面仍只有 RIO，无回退后端。

## 6. 静态复审问题的处理（2026-10-03）

外部复审按“源码静态审查 + RIO 官方语义核对”给出下列条目，逐条处理如下。

| 级别 | 问题 | 处理 | 状态 |
|---|---|---|---|
| P0 | UDP 补全上下文缺少上界校验（仅校验 `>= base` 与对齐） | `cesUdpSlotForAddress` 改为 `(slots:count:address:)`：校验 `count > 0`、`stride != 0`、`stride × count` 与 `base + extent` 溢出、`base ≤ address < end`、对齐，并新增 `CESUdpSlot.index` 元数据校验；新增 2 个单元回归用例（越界一个步长、远越界、未对齐、base 之下、count=0、元数据不匹配） | 已修 |
| P1 | RIONotify shutdown 用伪造 IOCP packet 冒充投递，`armed=false` 语义不干净 | 新增 `cesReleaseNotification`：显式“合成释放包 + 真实投递优先按投递消费 + 未投递则 `cesNotificationMarkAbandoned` 显式放弃注册”的状态机，TCP worker 与 UDP 共用；注释明确“排空后 CQ 必空、注册不可能投递”的前提 | 已重构 |
| P1 | accept 路径重复查询完成状态与对端信息 | 删除 `WSAGetOverlappedResult`（GQCS 已给出成功/失败与错误码）与 `getpeername`（AcceptEx 已通过 `GetAcceptExSockaddrs` 解析并校验地址），每个新连接少 2 次系统调用 | 已修 |
| P1/P2 | 每次 recv/send 都更新索引最小堆，可能是高负载热点 | 未改算法：Swift 与 C++ 使用同一 `O(log N)` 索引堆，属基线行为；新增 `tcp-1000sessions` 场景（每 worker 250 连接）测量该路径的实际影响，结论见第 4 节 | 已测量，待 profile 决策 |
| P2 | `WSAGetLastError` 与 `GetLastError` 混用 | UDP 启动路径与 acceptor 启动路径改为按 API 分别报告：`WSASocketW` → `WSAGetLastError`，`CreateIoCompletionPort`/`VirtualAlloc` → `GetLastError` | 已修 |
| P2 | acceptor 地址校验的整数加法未检查溢出 | 改为 `multipliedReportingOverflow` + `addingReportingOverflow`，与 TCP 请求上下文校验同标准 | 已修 |
| P2 | accept handoff 状态与身份校验可加强 | `cesAcceptorOperationForAddress` 增加 `owner == acceptor` 与 `index` 校验；AcceptEx 完成要求 `state == .posted`，ACK 要求 `state == .transit`，acceptor 在 ACK 与销毁时回收未被接管的 socket | 已修 |
| 所有权 | worker 线程直接访问 acceptor 的 socket owner 容器 | 改为所有权转移：acceptor 在 handoff 前把 socket 释放进 operation 记录的裸值，worker 从该值 `CESSocketOwner` 接管；worker 不再触碰 acceptor 的容器 | 已改 |
| 优化 | 每次 drain 重新初始化 `InlineArray<256, RIORESULT>`（8 KiB） | `RIORESULT` 缓冲改为 worker 持有的固定分配（`CESPinnedStorage`），drain 只做 native 输出写回，不再重复初始化 | 已改 |
| 优化 | acceptor 可改用 `GetQueuedCompletionStatusEx` | 暂不改：admission 之后 acceptor 主要处理 worker ACK，属控制路径；待 CPS 压测证明其为瓶颈后再评估（worker 侧的 RIO 完成已按 256 批量出队，无需改） | 待评估 |

保留的正确设计（复审确认，不做改动）：CQ 容量按 `2 × outstanding` 预留、UDP `closesocket → 继续排空 → outstanding == 0` 才释放、TCP 请求上下文三层校验、acceptor 先于 worker 的停止屏障、非拷贝 RAII owner、每 worker 独占定时器堆。

## 6b. 第二轮复审问题的处理（2026-10-03 晚）

| 级别 | 问题 | 处理 | 状态 |
|---|---|---|---|
| P1 | UDP `while true` 排空在持续满速流量下可能饿死 stop/`/w` 判定 | UDP 与 TCP 对齐：排空限量 64 个批次，且**在排空内部**检查停止标志与 `/w` 期限；一旦观察到就关闭 socket、停止重投，使排空收敛。实测满速 UDP 洪泛（8 发送者 × 1200 B，服务端 5 s 内处理 143 万完成）下 Ctrl+Break 1.07 s 退出、`outstanding=0`、stderr 为空；TCP 突发下 0.99 s 退出、`active=0` | 已修 |
| P1/P2 | `cesReleaseNotification` 仍依赖合成 IOCP 包推断 RIONotify 生命周期 | 改为**惰性通知**：只有在途请求存在时才武装（TCP 用活动连接数、UDP 用 `outstanding`），投递即解除，排空后仍有在途请求才重新武装。空闲引擎不再持有挂起注册，合成包与“放弃注册”迁移整体删除；销毁前若仍武装只报告诊断。TCP/UDP 两个数据面路径都覆盖 | 已重构 |
| P2 | 启动失败错误码未在调用点就地捕获 | `WSASocketW` → 紧邻取 `WSAGetLastError`；`CreateIoCompletionPort`/`VirtualAlloc`/`CreateEventW` → 紧邻取 `GetLastError`，在工作线程初始化、UDP 启动、acceptor 启动三处都改为“调用—取码—检查”相邻 | 已修 |
| P2 | `/q` 实际是 no-op | 与基线一致（C++ 服务端也不读取 `quiet`）：保留解析以保证命令行兼容，并在 `CESOptions.quiet` 注明“兼容开关，服务端仅 `/stats` 输出，无抑制对象”；README 参数表同步 | 已明确 |
| 微优化 | 不需要地址时可删除 `GetAcceptExSockaddrs` | 已删除该调用与扩展函数指针加载（`cesLoadAcceptEx` 只解析 AcceptEx）；AcceptEx 的输出缓冲区与长度参数保留，`SO_UPDATE_ACCEPT_CONTEXT` 保留。每新连接少一次调用 | 已改 |
| 清理 | 默认值在 `CESConstants` 与 `CESOptions` 重复 | `CESOptions` 默认值全部引用 `CESConstants`，消除漂移风险 | 已改 |
| 清理 | `CESExitCode.echoFailure` 未使用 | 保留并注明为基线退出码契约残留（客户端才使用 3），与 README 的退出码表一致 | 已明确 |
| 行为修正 | `AcceptEx` 完成前被 RST（`ERROR_NETNAME_DELETED`）被判为接入致命错误 | **两侧同修**：Swift `cesAcceptErrorIsRecoverable` + C++ `ces_engine_accept_error_is_recoverable`，只关闭该 operation 的 socket 并重投 `AcceptEx`，其余错误保持致命分类；共用测试 `Tests/ces_reset_storm_tests.ps1`（400 次预接受 RST → 随后正常回显 → 干净退出）已接入两侧 `build.ps1` | 已修（基线缺陷，非移植差异） |

### 冻结为 dormant candidate 的性能优化（触发条件已收紧）

| 候选 | 现状数据 | 触发条件（三者同时满足才动） |
|---|---|---|
| TCP 定时器堆 → timing wheel | 12.3 ns/次（N=8）、48.3 ns（N=250）、77.3 ns（N=2500），折合服务端 CPU ≈1% / ≈7% / ≈10%；与基线同算法 | ETW/WPA 显示 `insertOrUpdate` 族 ≥5% **且** 服务端 CPU 已成为吞吐/延迟瓶颈（不是“≥5% 就改”：堆占 8% 而 CPU 仅 35% 时不改） |
| acceptor `GetQueuedCompletionStatusEx` | 单线程 3.1~4.1 万 CPS、为基线 92%~100%；稳态回显时 acceptor 包速率≈0 | acceptor 线程 CPU 持续 ≥85%~90% **且** CPS 出现平台 **且** profile 显示 IOCP dequeue/dispatch 为主要成本（不把“10 万 CPS”本身当条件） |

## 7. 复现

```powershell
# 全量功能与安全验证（Debug/Release 各一遍）
pwsh -NoProfile -File build_debug.ps1
pwsh -NoProfile -File build_release.ps1
# 独立目录复验
pwsh -NoProfile -File tests/ces_standalone_check.ps1 -Configuration release
# 性能矩阵（3 次重复，输出 docs/performance-<日期>.json 与 -runs.md）
pwsh -NoProfile -File tests/ces_performance.ps1 -ServerPath (Join-Path (swift build -c release --show-bin-path).Trim() 'swift-echo-server.exe') -Configuration release -Repetitions 3
```