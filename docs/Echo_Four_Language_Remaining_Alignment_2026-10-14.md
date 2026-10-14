# Echo 四语言八仓库剩余对齐工作规约

**版本：** v1.0（2026-10-14 静态源码审查版）  
**目标平台：** Windows x64；Winsock Registered I/O（RIO）、IOCP、ConnectEx、AcceptEx  
**覆盖项目：** C++ / Rust / Zig / Swift，Client 与 Server 各一个，共八仓库  
**契约：** `echo-binary-contract-v1`  
**审查属性：** 只读 GitHub `main` 源码审查；**本次未编译、未运行 Windows 门禁、未修改或推送仓库**。文中“源码已实现”不等于“运行时已经验收”。

> **执行结论：** Swift Client 和 Server 已完成主要源码重组，但仍是 WIP 快照；先补齐故障驱动接线并修正经过复核的少量语义分歧，随后一次性运行 Swift Release/Debug 实际门禁。C++、Rust、Zig 没有发现需要整体重写的架构缺口；尚需解决 Handoff 异常政策分歧、公共验证器版本和能力清单、过时文档。项目目标是尽快冻结八个 Release 二进制、运行 **4×4×5** 跨语言正式对照，而不是无限叠加门禁。

---

## 1. 审查基线、证据等级与裁决规则

### 1.1 八仓库固定提交

| 语言 | Client（HEAD SHA） | Server（HEAD SHA） | 当前定位 |
|---|---|---|---|
| C++ | `0853573acac79aaa549e661d356cbc79f7f7e68e` | `68d808503899abd0be1d6bca87795b3eca226ec7` | 参考实现；不能假设参考实现无缺陷 |
| Rust | `e4efb273c7e1cf178f5f8021aef56c00de7a5a82` | `ac8bdee80bd89731f908ef2da84baeefc92749d4` | 核心架构与 C++ 对应，少量异常政策待裁决 |
| Zig | `371b02fe8df35af31a651684b4f149a19e2e64bb` | `28b471719273643681ad44ac9083099888d05e4e` | 已修复此前 TCP/UDP 所有权缺口，仍需最终比较 |
| Swift | `d8a847ab5e7dc55fbea636a030e71f4b16eda25a` | `dbaad11322d45cebb55dcb99e0bb90a755cb33a8` | **WIP 审查快照，尚无本轮构建/门禁验收证据** |

仓库主页：`https://github.com/iphone2059/<语言>-echo-<client|server>`，请以此处完整 SHA 而非浮动 `main` 作为历史审查锚点。若恢复工作时 HEAD 已变化，先制作增量差异清单，不得把旧快照当作新代码事实。

### 1.2 证据等级

| 标记 | 含义 | 可否宣称已完成 |
|---|---|---|
| **S0** | GitHub 源码／构建清单直接可见 | 可称“源码存在”或“明确缺失”，不可称运行成功 |
| **S1** | 三种参考实现对同一输入、事件序列行为一致 | 可确立目标契约；否则必须裁决冲突 |
| **T1** | 本机 Debug/Release 构建、CTest 或既有门禁退出码及日志 | 可称对应门禁通过，不能扩大至全语义 |
| **T2** | 固定输入的跨语言二进制互操作和故障边界证据 | 可称该组语义通过 |
| **P1** | 冻结编译器、EXE SHA、负载和环境后的正式性能采样 | 才能报告性能结论 |

### 1.3 冲突裁决层级

1. **已明确采用的共同二进制契约**与可复现实验为首位。
2. C++ 作为行为参照，但若 C++ 与 Rust/Zig 不一致，不能自动将它的缺陷推广至另外三种语言。
3. Rust/Zig 一致的纯状态机分解优先用于 Swift 内部架构映射；允许语言层惯用实现，禁止更改可观察语义。
4. `docs/echo-contract.md`、旧 `behavior-differences.md` 或其他历史文档，若与当前源码/`echo-binary-contract-v1` 冲突，先更新文档，不得把代码改回旧实现。
5. **构建成功、运行门禁成功、性能达标**是三项独立结论。

---

## 2. 总状态表：哪些已经完成，哪些仍阻断

| 工作域 | C++ | Rust | Zig | Swift Client | Swift Server |
|---|---|---|---|---|---|
| Windows Native RIO + IOCP | 参考已实现 | 已实现 | 已实现 | 源码已实现 | 源码已实现 |
| Client `Session/Scheduler/Core` | 参考已实现 | 已实现 | 已实现 | 已迁移 | 不适用 |
| Server `Connection/TCP/UDP/AcceptorCore` | 参考已实现 | 已实现 | 已实现 | 不适用 | 已迁移 |
| Native 提交账本与每 Slot 所有权 | 已实现 | 已实现 | 已实现 | 有独立标志与 posted 长度 | 有独立 providerOperation 与 posted 长度 |
| 停机排空、全 Join 屏障 | 已实现 | 已实现 | 已实现 | 源码已设计 | 源码已设计 |
| 每 Session 独立 TX/RX 注册 | 已实现 | 已实现 | 已实现 | 源码已实现 | 不适用（Server 采用每 Slot 注册） |
| 故障测试驱动 | 有 | 有 | 有 | 驱动新模式**未全部接线** | 驱动存在，**脚本缺失** |
| 本轮完整 Release/Debug 验收 | 参考既有证据 | 参考既有证据 | 参考既有证据 | **待执行** | **待执行** |
| 四语言统一验证脚本和 features | 新版 | 新版 | 旧版 | 旧版 | 旧版 |
| 最终冻结 EXE / 性能采样 | 待统一冻结 | 待统一冻结 | 待统一冻结 | 待统一冻结 | 待统一冻结 |

这里的“已实现”仅指当前源码可以找到对应结构与调用；除明确引用的历史测试外，**没有在本次审查中重跑任何门禁**。

### 2.1 两个已确定、不可跳过的 Swift 集成阻断

**阻断 SW-S-01：** `swift-echo-server/CMakeLists.txt` 注册 `fault-processes`，调用 `Tests/ces_fault_process_tests.ps1`；在当前仓库树中该脚本不存在。`Package.swift` 和 `Tests/CESFaultDriver/main.swift` 已包含测试可执行目标和多个场景，因此首选补**胶水脚本**，而非重做 Fault Driver。

**阻断 SW-C-01：** `swift-echo-client/Tests/cec_fault_process_tests.ps1` 仍只调用旧的约十种模式。新 FaultDriver 已提供 `e2e_missing_completion`、`e2e_cancel_positive`、`join_barrier_failure`、`worker_release_order`、`worker_slot_ownership`、`stale_generation`、`posted_extent` 等；尚未形成要求的进程级正反例配对验收。

**共同阻断 SW-B-01：** 两 Swift 最新提交的说明均为 `WIP: checkpoint Swift alignment for cross-machine review`；`docs/REVIEW_CHECKPOINT_2026-10-14.md` 明确没有完成本轮格式化、Swift 编译、CTest、Reset Storm、最终独立复审。

---

## 3. 物理文件、职责和依赖方向

### 3.1 Client 文件映射（Swift 八文件；Rust/Zig 九模块）

| Swift | Rust | Zig | 唯一责任 |
|---|---|---|---|
| `Sources/main.swift` | `src/main.rs` | `src/main.zig` | 入口、参数传递、控制台回调、进程退出 |
| `Sources/contract.swift` | `src/contract.rs` | `src/contract.zig` | CLI、诊断优先级、数值与容量约束 |
| `Sources/types.swift` | `src/types.rs` | `src/types.zig` | 数据类型、枚举、错误域、配置、常量 |
| `Sources/payload.swift` | `src/payload.rs` | `src/payload.zig` | 载荷生成及字节级校验 |
| `Sources/metrics.swift` | `src/metrics.rs` | `src/metrics.zig` | 统计账本、直方图、最终输出格式 |
| `Sources/native.swift` | `src/native.rs` | `src/native.zig` | WinSDK、Socket/Handle/CQ/Arena、独立注册、资源 Owner |
| `Sources/internal.swift` | `src/internal.rs` | `src/internal.zig` | Session、Scheduler、纯 WorkerCore、Timer、Event/Action |
| `Sources/engine.swift` | `src/engine.rs` | `src/engine.zig` | RioAdapter、静态 WorkerRuntime、IOCP Worker、协调器和终结释放 |

Rust `lib.rs` 和 Zig `root.zig` 为语言模块导出入口；Swift 由 `Package.swift` 声明 Core 与可执行 Target。**不应为了凑成九个 Swift 文件创建空 `lib.swift`。**

### 3.2 Server 文件映射（Swift 七文件；Rust/Zig 八模块）

| Swift | Rust | Zig | 唯一责任 |
|---|---|---|---|
| `Sources/main.swift` | `main.rs` | `main.zig` | 进程入口、终止码、控制台 |
| `Sources/contract.swift` | `contract.rs` | `contract.zig` | Server CLI、/memory、/cq、/k 的容量校验 |
| `Sources/types.swift` | `types.rs` | `types.zig` | 状态枚举、Failure、Statistics、Lifecycle/Event/Action |
| `Sources/native.swift` | `native.rs` | `native.zig` | Win32/RIO、Pinned Storage、CQ/注册/Arena Owner |
| `Sources/engine.swift` | `engine.rs` | `engine.zig` | 纯 TCP Engine；无直接 Native 句柄 |
| `Sources/internal.swift` | `internal.rs` | `internal.zig` | Connection、UDP Engine、AcceptorCore、Credit、Worker/Acceptor/UDP Runtime |
| `Sources/server.swift` | `server.rs` | `server.zig` | 启动组装、Stop/Join/检查/销毁、最终统计与诊断 |

**必须保持的依赖约束：** `Native Transport -> 标准化 Completion/Event -> Runtime -> Pure Core -> Action -> Runtime -> Native Transport`。Pure Core 不得读取 RQ/CQ、SOCKET、OVERLAPPED、RIO Provider Outstanding；Native 不得自行决定 Session 的 Echo/重连业务状态。

### 3.3 Swift 允许的语言级差别

- `~Copyable`、`borrowing`、`consuming`、`InlineArray`、`Span/MutableSpan`、SwiftPM 显式 Target、固定地址 Storage 属于语言表达差别，不要求机械对应 `struct`/`RAII`。
- `@safe` 只允许严格审查过的原生所有者，编译必须开启 strict-memory-safety 并把对应诊断视为错误。
- 性能热路径不使用 Task/Actor、动态 `any protocol`、每 Completion 分配 Array、随意 `class` 封装 Native Slot。
- 不以“更 Swift 化”为由替换 Winsock RIO/IOCP 或引入普通 `recv/send` 兼容后端。

---

## 4. Swift Client：剩余工作明细

### SW-C-01（P0）接入新 FaultDriver 场景

**位置：** `Tests/cec_fault_process_tests.ps1`、`Tests/CECFaultDriver/`、`CMakeLists.txt`。

**已有基础：** 旧脚本覆盖 `normal`、`notify_failure`、`corrupt_cq`、`notification_identity`、`outstanding_underflow`、`control_post_failure`、`arena_capacity`、`shutdown_stop_race`、`completion_range`、`completion_identity`。新主程序还有额外 Mode，生产代码无需为测试加开关。

**需完成：**

1. 在脚本中统一定义每个 Mode 的预期退出码（0/2/4）、预期 stderr 具名阶段、是否必须有非空 stdout，以及超时阈值。
2. 成对执行 `worker_release_positive`/`worker_not_started`、`join_barrier_positive`/`join_barrier_failure`、`drain_rio_positive`/`missing_rio_completion`、`drain_connect_positive`/`missing_connect_completion`、`operation_positive`/`duplicate_operation`/`posted_extent`/`stale_generation`/`socket_identity`（以当前驱动真实支持的别名为准，不允许凭文档发明 Mode）。
3. **真实 Provider 完成丢失证据：** `e2e_missing_completion <port>` 与 `e2e_cancel_positive <port>` 需要独立 TCP Peer。负例必须由真实 `RIODequeueCompletion` 观察并隐藏一次状态 `995` 的取消完成，随后生产 Drain Timeout（1460）在原生所有权未归还前 fail-fast；正例不得丢包，必须有真实取消完成且干净退出。
4. 先启动 Peer，待监听就绪再启动 Driver；输出与 stderr 异步读取，有界等待，超时 Kill 进程树并 WaitForExit；**不允许只检查 exit=4**，必须检查具名不变量与必要正向对照。
5. CTest 仍以一个 `fault-processes` 套件接线即可，不为每个 Mode 新增独立 CTest Entry；避免测试矩阵膨胀。

**完成定义：** CTest 能真正执行全部关键 Mode；无不存在的模式名称、无超时悬挂、无“收到任意 error 就算通过”、无泄漏的 Peer 进程。

### SW-C-02（P0）首次真实编译与优化 IR 验收

**位置：** `Package.swift`、`build.ps1`、`Tests/cec_optimization_gate.ps1`、`Tests/cec_optimization_checks.ps1`。

1. 先完成源码静态复核、修复 `swift-format` 不一致，再运行 `build_release.ps1`，接着 `build_debug.ps1`。每项在独立进程中取真实 `$LASTEXITCODE`。
2. Swift 当前指定 `swift-tools-version: 6.4`、Swift 6 语言模式、StrictMemorySafety；本地快照曾出现 6.5-dev 编译器。**实际 Swift/LLVM/SDK 版本必须写入构建清单，不可用 Swift 6.4 历史数据冒充新构建。**
3. Release 的 IR 检查应覆盖真实 `settleAttempt`、`handleCompletion`、`deliver`、`dispatch`、`retireRio`、`sendTail` 等路径。当前检查脚本已经从旧 `completeAttempt` 迁移为新符号集合；但 `-O -whole-module-optimization` 可能内联/重命名符号，**必须以实际 IR 为准确认门禁自身能可靠证明 ARC/全配置拷贝约束**。
4. 记录真实 `CECWorkerConfiguration` 布局探针值，不能硬编码旧 288 bytes 或直接取消“热路径禁止整份配置复制”约束。
5. 对 `Sources/engine.swift` 的 `retireRio` 边界添加一次只读逻辑检查：`sendPostedBytes - sendOffset` 当前在 `owned` 检查之前计算。需要确认差值不会因损坏状态下的下溢而先触发 Swift trap，抢在具名不变量诊断之前。若确认有缺口，把有效偏移验证放到减法前，不改变正常数据路径。

**完成定义：** Release/Debug CTest 真正执行且退出 0；IR 约束使用实际产物，失败不会被 `Tee-Object`/管道尾端掩盖；无不受控制的 Swift Trap 替代原生失败分类。

### SW-C-03（P1）业务/Provider 两套账本的交叉核对

**源码已发现：** `Sources/internal.swift` 的 `CECWorkerCore` 与 `CECSession` 独立于 `Sources/engine.swift` 的 `CECRioAdapter`；Native Slot 有 `connectOutstanding/sendOutstanding/receiveOutstanding` 和 Posted Bytes；`GenerationDrained` 只有所有 Provider 完成退休后才发布。

**只需静态核对六个边界，不需要重新设计架构：**

| 边界 | 必须成立的条件 |
|---|---|
| ConnectEx 同步接受 / `ERROR_IO_PENDING` | 仅被 Provider 接受的请求进入 Outstanding；ConnectEx Completion 以原代际身份退休 |
| 接收与发送同时在途 | Send Completion 只能退休 Send Flag；Receive Completion 只能退休 Receive Flag |
| RIO 部分发送 | 使用同一原始 Attempt 的 TX 区间继续投递尾部；不能重复认领 `/n` |
| Receive 异常或 Echo 不匹配 | 完成状态、业务 `lost/corrupted` 和退出码分开处理，仍退休另一方向的 Provider 引用 |
| Close / Stop / Reconnect | 关闭 Socket 仅发起取消，不自行减少原生 Outstanding；首次 Close 锚定不可延长的 5 秒 QPC 宽限 |
| Release / Destroy | Join-all -> 集中检查 -> 快照 -> 释放；CQ 关闭、Buffer ID 注销、Arena 释放顺序不交叉；每个 Release 内部重复所有权 Guard |

在同一有限额度场景核对 `attempted = pending + echoed + corrupted + lost + cancelled`、`bytes`/`sent_bytes`/`received_bytes` 和 `active=0`。完成对照后，不再额外添加大量重复单元测试。

---

## 5. Swift Server：剩余工作明细

### SW-S-01（P0）补齐缺失的进程故障门禁脚本

**已确认结构：** `Package.swift` 定义 `CESFaultDriver`，`CMakeLists.txt` 注册 `fault-processes` 并引用 `Tests/ces_fault_process_tests.ps1`，当前树缺少后者。

**实现方式：** 新建该脚本，使用现成 `swift-echo-server-fault-driver.exe`，按模式表调用，检查退出码、原始 stderr 的阶段与 `native_error`、stdout 正向标志、子进程清理、超时。不要复制 Client 的业务案例；Server 的责任是 AcceptEx、RIO Server Worker、UDP 和 Join/释放。

**最小 Mode 分组：**

| 场景 | 已有 Driver 模式 | 断言要点 |
|---|---|---|
| 基础 FailFast | `normal`、`notify_failure`、`notify_duplicate`、`corrupt_cq`、`outstanding_underflow`、`control_post_failure` | 合法正例 0；非法必须 4 + 对应阶段 |
| 完成所有权 | `completion_positive`、`completion_range`、`completion_alignment`、`completion_identity`、`completion_length`、`completion_owner` | RequestContext 范围/对齐/元数据/Length/Provider 所有权 |
| Worker 释放 | `worker_release`、`worker_release_order`、`worker_release_positive`、`slot_release`、`slot_release_positive` | Guard 在任何 CQ/Arena/Heap 释放之前发生；合法释放 0 |
| Acceptor 释放 | `acceptor_release_order`、`acceptor_release_positive` | 有未退休 AcceptEx 不得提前释放；合法路径通过 |
| Arena 释放 | `arena_release`、`arena_deinit`、`arena_release_positive` | 请求在途触发命名不变量；正常退休后可释放 |
| 真实排空 | `worker_missing_completion`、`worker_cancel_positive`、`partial_startup` | 真实 Worker/AcceptEx/RIO 取消，部分启动也需完整 Join |
| 端到端缺失完成 | `e2e_missing_completion <port>`、`e2e_cancel_positive <port>` | 真实 `995` 被扣留与不扣留的负/正对照；完整原生排空边界 |

**注意：** 上表是已有 `Tests/CESFaultDriver/main.swift` 中的模式分组，不意味着所有 Mode 都期待相同退出码。`partial_startup` 可属于明确返回网络错误（2）的受控边界；其他模拟内部损坏需命名为退出 4。**以驱动真实控制流及 C++/Rust/Zig 共同故障契约核准每个 Expected 值，不能为了得到 PASS 修改生产逻辑的退出类别。**

**完成定义：** CTest 不再缺文件，FaultDriver 运行不滞留进程，错误阶段与退出类别有明确正反证据。

### SW-S-02（P0/P1）TCP/Acceptor Native 所有权和停止时序

**现有源码：** `CESTcpEngine` 位于 `Sources/engine.swift`；`CESAcceptorCore`、`CESAdmissionCredits` 和 Native Worker/Acceptor 位于 `Sources/internal.swift`。已经有 `providerOperation`、`postedLength`、Join 屏障和 `providerOwned`。

**必须核对的停机顺序：**

```text
Stop / Failed 发布
    ↓
停止 AcceptEx Admission；关闭 Listener；取消仍 Posted 的 Accepted Socket
    ↓
等待 Acceptor 的所有真实完成、Deferred 控制包、Handoff ACK；Join Acceptor
    ↓
向全部已启动 Worker 发布 AdmissionClosed
    ↓
向全部已启动 Worker 发布 Stop
    ↓
Join ALL Workers（包括启动失败后仍已创建的线程）
    ↓
统一校验 providerOutstanding、businessOutstanding、活动数、Timer、Credit、Notify
    ↓
最后才 Destroy/Close CQ、注销 Buffer、释放 Arena/Context/Acceptor Table
```

**三个已确认值得复查的接口细节：**

1. `cesAcceptorStop()` 当前按 `operation.providerOwned` 关闭 Socket。逻辑上这对应已投递的 AcceptEx；需断言 `providerOwned ↔ Core Posted` 的过渡关系，不能让 `transit` 的 Socket 被 Acceptor 提前关闭。历史 Zig 已有一条确定性 A/B（8/8）验证过“错误关闭 Transit”的危害。
2. `CESAcceptorCore.returnSlot()`、`deferRepost()` 目前可直接写入状态；它们缺少与 `markPosted()` 对称的非法状态前置条件。建议补最小 FailFast/Action 守卫，并确保调用者不会在 Provider 尚持有 Operation 时归还槽位。
3. `cesAcceptorHandoff()` 停止、全局失败、listener/socket 无效的分支目前合并为同一撤回；与 Zig 的健康状态非法 Socket 策略不一致，必须先作共同裁决（第 7 节），再定点修改。

**完成定义：** Posted 被 Stop 取消；Transit 仅由 Worker 接管或撤回并 ACK，Acceptor 不抢先释放；所有 Credit 归还恰好一次；非停机的 Provider 非法完成不被吞掉。

### SW-S-03（P1）TCP/UDP Provider 账本和异常计数

| 模块 | 当前实现 | 重点核对 |
|---|---|---|
| TCP Worker | `cesWorkerNormalizeCompletion` 校验 RequestContext 范围、步长、Owner、Index、Operation、Posted Length | 原生退休先于 Core 事件；失败状态也必须退休一次；不能复用未退休的 RIO_BUF |
| TCP Pure Engine | `CESTcpEngine.onCompletion/onPostFailure/close` | 业务计数与 Native Posting 账本独立；部分发送/零字节发送/超范围分类对应参考 |
| UDP Pure Engine | `CESUdpEngine.markPosted/onEvent` | 逐 Slot Operation、Outstanding 与总 Outstanding 一致；非法重复 Post 不增账本 |
| UDP Runtime | `cesUdpExecute/cesUdpDrain` | 原生 Post 成功才登记 Provider；失败 Post 不减少别的在途请求；关闭先停重投，等真实完成清零才释放 |
| Notification | `RIONotify`、IOCP Key/OVERLAPPED 与快照 | 只处理真实投递，不以伪造 Completion 抹平缺口；允许具约束的合法残留 Gap |

**Swift Server 目前有 `try!` 的便利初始化（如纯 `CESTcpEngine` 和 `CESUdpEngine`），但生产路径使用可失败的 checked 初始化。** 先验证没有生产调用依赖 `try!`；不要仅因测试辅助路径存在 `try!` 就重写所有构造器。大内存 OOM 应返回 Failure，不应崩溃后伪报网络错误。

### SW-S-04（P1）输出、统计和诊断

Server 最终 `/stats` 应保留字段与顺序：

```text
final protocol=... elapsed_ms=... workers=... accepted=... active=0
outstanding=... completions=... receives=... sends=...
received_bytes=... sent_bytes=... bytes=... network_errors=...
rejected=... MiB_per_sec=...
```

检查 `workers` 是实际启动线程数；UDP 固定一个 Worker；成功取消不增加 Network Error；AcceptEx 失败、普通 Socket 重置、RIO Post 拒绝与内部不变量分开归类；`CES_DIAG_FILE` 只在所有工作线程 Join 后输出且不改变进程退出码。Swift 源码实现了诊断写入，但 `features.txt` 尚未正确声明（第 8 节）。

---

## 6. C++ / Rust / Zig 已确认一致项与仅需核对项

### 6.1 当前源码一致的核心设计

- Client 每 Session `/n` 配额、一次 Attempt 的 Send/Receive 契约、代际退休、QPC Deadline、Stop/Timer 优先级及 64 批有界排空已有相应实现。
- C++、Rust、Zig Client **目前都是每 Session 独立 TX 和 RX RegisteredBuffer**；不是某些旧文档所说的共享 RX 注册。C++ `cec_engine.cpp` 有每会话两注册；Rust `src/native.rs` 的 `send_registrations/receive_registrations` 是按 Slot 分配；Zig `src/native.zig` 的两个注册数组也是按 Slot 分配。
- Server 的 TCP Connection、Acceptor 与 Credit、UDP 每 Slot 账本、RIO Post/Completion、接入停止和 Join-before-release 已有对应实现。
- Rust/Zig 的架构层级不同文件内部可以有职责差异（例如 Coordinator 所在模块），不能以物理函数位置不同判作语义不一致。

### 6.2 暂未确认、不得直接宣称“完全等价”的边界

- Accepted Socket 无效但全局尚未 Stop 的 Handoff 行为（第 7 节）。
- Native 失败时最具体 `stage`、`native_error` 捕获时点，以及错误是否计入 `network_errors`。
- 罕见的 Partial Worker Start、Provider Completion 丢失、CQ Notify Gap 和 shutdown-storm 情况；已有测试不代表本次同时重跑。
- 包含 Zig/Swift 在内的**相同版本公共二进制验证器和同一 Features 集合**（第 8 节）。

**工作原则：** 除第 7 节经裁决的差异外，不主动修改 C++、Rust、Zig 的正常路径；将精力留给 Swift 的最终集成。

---

## 7. 跨语言争议 CL-01：健康状态下无效 Accepted Socket

**这是本次复核后需要纠正历史报告的地方。** 先前有一版审查把 Rust 解释为“健康状态无效 Socket 会 fatal”，这是不准确的。Rust `handoff()` 遇无效 Socket 返回 `Withdrawn`，调用方对 `Withdrawn` 执行 `abort_handoff`，而不是升级为 fatal。

| 实现 | Stop / Failed / Listener 无效 | 未 Stop、未 Failed，但 Accepted Socket 为 INVALID |
|---|---|---|
| C++ `ces_engine.cpp` | 关闭并撤回 | 同样关闭并撤回 |
| Rust `internal.rs` | `Withdrawn` | `Withdrawn` + `abort_handoff` |
| Zig `internal.zig` | `withdrawSlot` | `handoffDisposition.fatal`，阶段 `AcceptEx handoff invariant` |
| Swift `internal.swift` | 关闭并撤回 | 同样关闭并撤回 |

**共同已一致的正常语义：** AcceptEx 成功后，运行中必须设置 `SO_UPDATE_ACCEPT_CONTEXT`、配置 Socket、获取必要地址信息、取得 Admission Credit，才能将 Socket 移交 Worker；`Transit` 期间 Acceptor 不得擅自关闭已交接 Socket。

**需要明确裁决的异常策略：**

- **策略 A（更严格，建议的目标）：** 只在 `stopping || failed || listener invalid` 时撤回；健康情况下 accepted socket 不存在意味着内部所有权不变量损坏，具名 fail-fast 退出 4。这样与 Zig 一致，但需对 C++、Rust、Swift 做最小修订。
- **策略 B（兼容当前多数实现）：** 该特定无效 Socket 场景统一撤回、不计新的 Network Error，前提是有显式的合法取消时序证据；Zig 改为撤回。这样保留 C++/Rust/Swift 的当前结果。

**禁止混合：** 同一事件序列不能在 Zig 退出 4、C++ 却静默继续后仍宣称“二进制行为完全一致”。建议团队在一个共同 `HandoffDisposition` 真值表上只作一次裁决，再将差异修复收敛为极小的提交。不要靠普通 Echo 测试碰运气复现这个异常。

**最小判定矩阵：**

| stopping | failed | listener valid | accepted socket valid | 期待 |
|---:|---:|---:|---:|---|
| 0 | 0 | 1 | 1 | handoff |
| 1 | 任意 | 任意 | 任意 | withdraw |
| 任意 | 1 | 任意 | 任意 | withdraw |
| 0 | 0 | 0 | 任意 | withdraw（listener 生命周期终止） |
| 0 | 0 | 1 | 0 | 按所选策略 A 或 B 一致 |

**注意：** `WSAENOTSOCK (10038)` 是“调用时 Socket 无效”的信号，但不能凭数字反推出唯一原因。历史 Zig 对照修复已删除多余 `WSAGetOverlappedResult`，并在 Native 失败处就地捕获错误码；不要把错误码覆盖问题重新引入 Swift。

---

## 8. 跨语言争议 CL-02：共同验证器与 Features 元数据

### 8.1 必须统一验证能力，否则 PASS 无法横向比较

| 仓库集合 | `tools/verification/test.ps1` | 已观察差异 |
|---|---|---|
| C++ Client/Server、Rust Client/Server | **723 行**的新版 | 可直接传 `ExecutablePath`、`PeerPath`、`Configuration`、`ArtifactDirectory`，具有 `GateSelfTest`、模式身份与更强的诊断证据 |
| Zig Client/Server、Swift Client/Server | **508 行**的旧版 | 通过相对 `executable.txt`/`peer-*.txt` 解析路径，缺少新版独立二进制/模式/产物控制接口 |

这是**测试能力差异，不是自动等价的实现差异**。C++/Rust 的 PASS 与 Zig/Swift 的 PASS 不能在未核准 Assertions 集合前直接认为同一覆盖范围。

### 8.2 建议执行方式

1. 以经审查的 723 行新版为统一 `tools/verification/test.ps1`，八仓逐一比较文本哈希。**禁止只复制一份但没确认每个仓库脚本仍能找到其 EXE 和 Peer。**
2. 通过明确传递 `ExecutablePath`、`PeerPath`、`Configuration`、`ArtifactDirectory` 调用，不要让测试去猜 Debug/Release 同路径中的哪个 EXE。
3. `features.txt` 应反映**已实现且可验收**的能力，不因是 Swift/Zig 而省略。C++/Rust Server 声明 `notify-diagnostics`；Zig Server、Swift Server 代码已支持 `CES_DIAG_FILE`，但当前 Features 未声明，应验明格式后补声明。
4. Zig/Swift Client 暂未获得相同证据证明存在 `CEC_DIAG_FILE` 的完整实现；不得单凭 C++/Rust Client 支持就直接声明此 Feature。先补实现或明确按合同降级，不能伪造。
5. Features 作为能力发现不等于豁免关键契约：如果 `notify-diagnostics` 是本次强一致目标，就必须八仓对应 Client/Server 都满足，而不能靠删掉标记使测试跳过。
6. 公共验证器只需**一次真实自测**（非法二进制路径、脚本自身失败传播、模式身份），然后执行本次最终互操作，不再无目标地加轮次。

### 8.3 当前 `contract-version.txt` 的意义

八仓都是 `echo-binary-contract-v1`；**版本字符串一致并不足以证明所有源实现和实际测试 Assertions 一致**。记录验证器文件 SHA、Features 内容、被测 EXE SHA 才构成可比证据。

---

## 9. 文档差异 CL-03：只更新事实，不重写程序

**已确认过时：**

- `rust-echo-client/docs/status.md` 仍描述共享 RX RegisteredBuffer；当前 `native.rs` 是按 Slot 独立 RX 注册。
- `zig-echo-client/docs/parity-contract.md` 仍描述共享 RX 注册；当前 `native.zig` 的 `receive_registrations` 是每 Slot 一份。
- `swift-echo-client/docs/behavior-differences.md` 仍描述旧 `(sessions + actualWorkers) × batch` 内存结构、全局配额 CAS 等；新源码报告说明已经迁移至每会话双方向窗口和纯 Core/Worker 本地配额。
- `swift-echo-server/docs/behavior-differences.md` 的若干历史描述（如“基线一直排空到空”）与当前 64 批有界排空不一致；重新确认并修订。
- Swift `docs/REVIEW_CHECKPOINT_2026-10-14.md` 在最终通过后应保留为**历史 WIP 记录**，另新增最终验收文档，不能悄悄改写为“当时已经通过”。

**规则：** 文档修改单独提交或与对应微小修复提交；绝不把历史记录、未通过门禁或原始失败证据清除。

---

## 10. 二进制语义验收矩阵（一个最小且完整的共同集合）

下表用于**筛选现有测试**，不是要求每行新建一个套件。优先复用 Rust/Zig 既有 Core 与 FaultDriver；Swift 只增加必要的接线和缺失断言。

| ID | 输入或事件序列 | 期望的统一结果 | 参考边界 |
|---|---|---|---|
| C01 | CLI 无协议、缺 Target、非法数值、UTF-16 破损 | 同诊断优先级、同退出 1 | `contract.*` |
| C02 | `/n`、`/c`、`/k`、`/threads 0`、容量极限 | `/n` 每 Session、容量和合法零值一致 | `types/contract` |
| C03 | TCP 字节分片及短接收 | WAITALL 与失败分类相符，不吞失配 | `Session/Transport` |
| C04 | 一次 Receive + Send 并发，任一完成先到 | 两种顺序都能正确结账，不提前开始下一 Attempt | `WorkerCore` |
| C05 | Partial Send 连续若干完成 | 累积字节精确，尾部续发且不重复 Claim | `RIO Transport` |
| C06 | TCP/UDP Payload 不一致、0 字节 UDP、短 UDP | 比较、丢失/损坏分类和长度完全一致 | `payload/metrics` |
| C07 | ConnectEx 或 RIO 失败后 Reconnect | 旧 Generation 完成只退休，不驱动新代业务 | `generation` |
| C08 | Stop 与真实 Completion 交错 | 已获得 Completion 先入账；Stop/Timer 后裁决 | `IOCP arbitration` |
| C09 | 5 秒 Drain 宽限最后 Completion 丢失 | 不能释放 Provider 仍引用的内存；具名 1460/内部失败 | `drain` |
| C10 | RIONotify 实投/重复武装/合法残留 Gap | 不合成通知；合法 Gap 允许；非法 Gap FailFast | `notify` |
| S01 | AcceptEx 成功/失败、3 类可恢复 Reset | 仅需要 Repost 的情形重投，其他按共同分类 | `AcceptorCore` |
| S02 | Posted、Transit、Deferred、Idle + Stop/ACK | 仅取消 Posted，Transit 等 ACK；Slot 恰好归还一次 | `Handoff` |
| S03 | 全 Worker 满载、Admission Credit 拒绝 | 不超发；rejected 与 credit 一致 | `AdmissionCredits` |
| S04 | TCP Provider 同步 Post 拒绝 / 异步 Completion 失败 | 独立 Native 账本与业务账本完整 | `CESTcpEngine` |
| S05 | UDP 两 Slot 交错、重复 Completion、重复 Post | 不允许错误扣除其他 Slot Outstanding | `CESUdpEngine` |
| S06 | UDP 10054 Reset | 恢复全容量接收，不静默漏报相应网络事件 | `UDP Runtime` |
| S07 | 关闭/取消/部分 Worker 启动失败 | 全 Join、集中检查，再释放；不 double-close | `Coordinator` |
| S08 | 不同阶段 Native 错误 | 原始错误在调用点捕获，stage、网络计数和退出类别对应 | `Failure` |
| E01 | 4×4 中任一 Client 与 Server TCP/UDP 互操作 | 字节一致、退出一致、终态账本平衡 | `verification/test.ps1` |

**强制不变量：** 任意 Native Release 前 `providerOutstanding == 0`；Client 尚未退休的 Generation 不可复用；Server Credit 不可重复 Release；任何“异常 Exit 4”测试必须有合法正向对照。

---

## 11. 失败类别和日志证据的统一规则

| 事件 | Exit 类别 | 统计 | 诊断/资源规则 |
|---|---|---|---|
| 正常完成 / 受控 Stop | 0 | 完整结账，active=0 | 正常关闭与取消 Completion 不应误记新网络错误 |
| Usage / CLI / 资源容量配置非法 | 1 | 按现行契约 | 先按消费顺序确定 Diagnostic Token |
| 真实网络准备/运行失败 | 2 | 按 Stage 累积 `network_errors` | 失败点立刻捕获 Winsock 或 Win32 原始错误 |
| Client Echo 业务失败 | 3 | lost/corrupted 与 pending 严格结账 | 与 Native provider 不变量区别 |
| Completion/所有权/排空不变量 | 4 | 不伪装成网络错误 | 具名 fail-fast；不得边释放仍在途 RIO 边“恢复” |

**典型签名：** `SO_UPDATE_ACCEPT_CONTEXT` 失败出现 `10038` 时，应保留当次真实状态，不调用别的 Win32 API 后再读取 LastError；取消 Completion 的 `995` 应按是否 Stop/Closing 处理，不能被已关闭 Listener 上的二次查询改写成 `10038`。RIO RQ 创建失败的 `10055` 也不能无证据直接解释为资源耗尽。

**PowerShell 证据模板（从仓库根目录运行，一次验收）：**

```powershell
pwsh -NoProfile -File .\build_release.ps1 *> .\release-final.log; $release=$LASTEXITCODE; Write-Host "RELEASE_EXIT=$release"; if ($release -ne 0) { throw "Release gate failed: $release" }
pwsh -NoProfile -File .\build_debug.ps1 *> .\debug-final.log; $debug=$LASTEXITCODE; Write-Host "DEBUG_EXIT=$debug"; if ($debug -ne 0) { throw "Debug gate failed: $debug" }
```

不要使用 `build.ps1 | Select-String` 的最后一级命令退出码替代真正构建退出码；任何红灯必须保存原始日志，禁止靠反复重跑挑选成功结果。**依仓库 AGENTS.md，“门禁未全绿不得推送”的约束继续有效**；历史 WIP 暂存推送须明确标记例外，而不是伪称正常验收。

---

## 12. 速度优先的实施批次与依赖图

### 阶段 I：Swift 缺失接线（先做，不动三套参考引擎）

| 工单 | 责任仓库 | 变更文件 | 完成输出 | 限制 |
|---|---|---|---|---|
| SW-S-01 | Swift Server | 新 `Tests/ces_fault_process_tests.ps1` | CTest 找到并执行 Fault Driver | 不新建生产抽象 |
| SW-C-01 | Swift Client | `Tests/cec_fault_process_tests.ps1` | 全部关键新 Mode 正反配对 | 不新增冗余测试二进制 |
| SW-C-02/SW-S-02 | Swift 两仓 | 仅复核发现的问题 | 源码静态审查闭环 | 不进行无关重构 |

### 阶段 II：一次共同语义裁决与验证器收敛

| 工单 | 目标 | 实施结果 |
|---|---|---|
| CL-01 | 健康无效 Socket 策略 A/B | 一张共同真值表，最小代码差异或明确例外 |
| CL-02 | 723 行共同 `test.ps1` | 八仓文本一致、模式/EXE/工件路径明确 |
| CL-02b | Features 声明 | 实际行为与 Flags 一一对应，特别是 Notify Diagnostic |
| CL-03 | 文档清理 | 当前源事实更新；历史 WIP/失败记录保留 |

### 阶段 III：仅一次必要的最后门禁

1. 对完成源码审查的两个 Swift 仓库分别 `format.ps1 -> build_release.ps1 -> build_debug.ps1`。现有 CTest 负责 Unit、Ownership Compile、StrictMemorySafety、Fault Process、Reset Storm、Interop、IR（Client Release）；不再人为追加普通 Echo 循环。
2. 若涉及 C++/Rust/Zig 的 CL-01 修改，仅对修改仓库运行既有受影响门禁及统一共同契约；未改动仓库无需为了“仪式性验收”重复几十轮。
3. 每个失败都保留原始日志；修复真实错误后重跑**失败所需的最小门禁与最终 Release/Debug 验收**，不增加额外实验条件。
4. Eight EXE 的编译器版本、构建配置、Git HEAD、SHA-256、验证器 SHA、Features 内容冻结后，立即进入正式性能测试。

**禁止扩展范围：** 不改 C++/Rust/Zig 正常 RIO 热路径，不引入 IOCP/RIO/IORING 多后端比较，不重命名整个架构，不为 Swift 补空模块，不在当前阶段单独解决 4096 Session Soak 或新增 30/60 轮 A/B。

---

## 13. 四语言性能基线：冻结、执行和解释

### 13.1 运行配置

- 比较对象：**4 Client × 4 Server = 16 种配对**；同一台 Windows x64 主机、同样环境和负载。
- 工作负载：沿用已冻结的五项 `tcp_128_k1`、`tcp_4096_k8`、`udp_1200`、`udp_65507`、`tcp_128_c1024`；每一项 Echo Count 不再根据某一语言的吞吐单独调整。
- 每项每配对两轮 Warmup、七轮正式采样；总计 **160 轮 Warmup + 560 轮正式样本 = 720 轮运行**。如果只做 3×3 对照，则是 90 Warmup + 315 正式样本，与四语言批次不可混写。
- 4096 Session 极限 Soak 继续单列；不当作五项正式负载之一，除非共同契约显式新增并重新冻结。
- Warmup 本身验证配置、退出码、日志、回显完整度；出错停止当前批次，不挑一个成功的样本替换失败轮。

### 13.2 产物清单

| 文件/字段 | 必须包含 |
|---|---|
| `binary-manifest.json` | 8 个 EXE 的绝对路径、SHA-256、Language、Role、Git HEAD、工具链、优化参数 |
| `verifier-manifest.json` | `test.ps1` SHA、Features、版本字符串、运行模式与断言集 |
| `workload-manifest.json` | 五项固定参数、端口分配、Warmup/正式轮次、批次 ID |
| 每轮原始记录 | Client/Server exit、stdout、stderr、耗时、吞吐、字节、错误、CPU/内存、时间戳 |
| 汇总 | 每组合每负载的分布统计、相对 C++ 对照、失败次数、置信区间/离群解释 |

既有二进制直方图暴露的延迟字段以 `p50_us~ / p99_us~ / p999_us~` 为主；**不得把不存在的原始 p95 当成“已测”**。若要增加 P95，必须从足够粒度的原始数据正确计算并标注采样与分桶误差。

### 13.3 通过门槛与报告边界

- 功能：所有必要的互操作无载荷损坏、无意外丢失、Native 出错无假成功；Stop/Cancel 后所有权可安全释放。
- 统计：Client attempted/pending/Echo/Cancelled/Lost 平衡，Server bytes、send/receive、active/Outstanding 一致。
- 性能：**先出数据，不预设“Swift 必须达到 C++ 的 X%”**。不同编译器、运行时、ARC、优化路径的开销要由冻结数据说明，禁止为跑分改动契约。
- 历史 352 轮与本次新二进制不可合并；旧 Swift 2026-10-02/03 性能报告不能当作当前重构结果。

---

## 14. 最终验收单（只保留真正阻断）

| 编号 | 放行条件 | 当前 |
|---|---|---|
| G1 | Swift Server Fault Process Script 存在、可运行、正反例明确 | 未完成 |
| G2 | Swift Client 新 Fault Driver 关键 Mode 真正进入 CTest | 未完成 |
| G3 | Swift Client/Server 源码静态复核结束，只有经过证据确认的差异被修改 | 未完成 |
| G4 | CL-01 健康无效 Socket 策略已统一或登记经批准例外 | 未决 |
| G5 | 八仓公共验证器与 Features 可核对同一断言集 | 未完成 |
| G6 | 两 Swift 最新源码 Release、Debug 真正通过 CTest/Reset Storm/相关互操作 | 尚无证据 |
| G7 | 八 EXE 身份、编译器、SHA、完整门禁产物已冻结 | 未完成 |
| G8 | 五项既定负载 Warmup 成功，正式 4×4 采样开始 | 未开始 |

**非阻断维护项：** 过时文档更新、缺少性能剖析的优化候选、测试覆盖之外的额外压力重复、4096 Session Soak、故障注入编译期限定（前提是生产路径确实不可触达且不破坏语义）。这些不能代替 G1–G8，也不能无限推迟正式基线。

---

## 15. 具体源码和证据索引

**八仓固定地址：**

- C++ Client：<https://github.com/iphone2059/cpp-echo-client/tree/0853573acac79aaa549e661d356cbc79f7f7e68e>
- C++ Server：<https://github.com/iphone2059/cpp-echo-server/tree/68d808503899abd0be1d6bca87795b3eca226ec7>
- Rust Client：<https://github.com/iphone2059/rust-echo-client/tree/e4efb273c7e1cf178f5f8021aef56c00de7a5a82>
- Rust Server：<https://github.com/iphone2059/rust-echo-server/tree/ac8bdee80bd89731f908ef2da84baeefc92749d4>
- Zig Client：<https://github.com/iphone2059/zig-echo-client/tree/371b02fe8df35af31a651684b4f149a19e2e64bb>
- Zig Server：<https://github.com/iphone2059/zig-echo-server/tree/28b471719273643681ad44ac9083099888d05e4e>
- Swift Client：<https://github.com/iphone2059/swift-echo-client/tree/d8a847ab5e7dc55fbea636a030e71f4b16eda25a>
- Swift Server：<https://github.com/iphone2059/swift-echo-server/tree/dbaad11322d45cebb55dcb99e0bb90a755cb33a8>

**优先阅读的文件：**

1. Swift Client：`docs/REVIEW_CHECKPOINT_2026-10-14.md`、`docs/review/2026-10-14/client-report.md`、`Sources/engine.swift`、`Sources/internal.swift`、`Tests/cec_fault_process_tests.ps1`、`Tests/cec_optimization_checks.ps1`。
2. Swift Server：`docs/review/2026-10-14/server-audit.md`、`Sources/internal.swift`、`Sources/engine.swift`、`Tests/CESFaultDriver/main.swift`、`CMakeLists.txt`。
3. 三语言对照：C++ `src/ces_engine.cpp`、Rust Server `src/internal.rs`、Zig Server `src/internal.zig`；C++ Client `src/cec_engine.cpp`、Rust Client `src/native.rs`、Zig Client `src/native.zig`。
4. 共同规范：`swift-echo-client/docs/CPP_Rust_Zig_Swift_Refactoring_Spec_v2.0.md` 及各仓 `tools/verification/*`。

---

## 16. 一句话执行指令（可直接交给开发 Agent）

> 以本规约列出的八仓固定 SHA 为审查基线，C++ 保持正常行为参考、Rust/Zig 保持现有架构。优先补齐 Swift Server 缺失的 Fault Process PowerShell 脚本和 Swift Client 新 FaultDriver 接线；审核 Swift 原生生命周期、代际排空、Join 先于释放以及 Debug/Release 真实编译。对健康状态无效 Accepted Socket 的 C++/Rust/Swift 与 Zig 分歧只做一次统一契约裁决和最小修改；把公共验证器和 Features 统一到相同断言集合。禁止无关重构、无限重复门禁或性能预优化。取得真实门禁退出码与完整日志后，冻结八个 Release EXE 和各自 SHA，立即开展相同五项工作负载的 16 配对、两轮 Warmup、七轮正式性能基线。任何失败必须记录原始证据，不得用筛选管道退出码、旧性能报告或重跑挑绿替代验证。

**文档结束。**
