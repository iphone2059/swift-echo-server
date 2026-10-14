# Swift Server 独立静态复审 — 2026-10-14

审查结论：完整源码静态复审已完成；初次发现的 **1 个 P1 二进制账本一致性阻塞已由根代理修复并完成只读复核**。当前没有本次审查发现而尚未关闭的源码阻塞。此结论仅为 S0/S1 源码证据，不代表 Swift 编译、ABI、进程故障门禁、reset storm 或运行时验收已经通过。

本审查没有修改生产源码、测试或脚本，没有执行 format、编译、Swift 探针、单元/进程测试、commit 或 push。唯一写入工件为本报告。最新用户要求以 SwiftPM build/test 为入口、由 PowerShell 编排原生故障/reset/所有权/safety/IR 门禁；旧规约中的 CMake/CTest 不是当前验收要求。脚本与 SwiftPM-only 接线由根代理独立审查。

## 发现与关闭

### P1 / SR-S-01：Acceptor IOCP 原生失败漏记一次 network_errors

**状态：已关闭（源码复核）。** 根代理现于 `Sources/internal.swift:882` 在非超时失败分支执行 `core.statistics.networkErrors &+= 1`，随后 `:883` 使用原先已捕获的 error 调用 `cesAcceptorFail`，`:884` 返回 true。`:880` 的 WAIT_TIMEOUT 仍先返回 false；非 nil OVERLAPPED 的真实 AcceptEx 完成与控制包已在前面的分支返回，因此它们不会重复进入新增计数。通用 `cesAcceptorFail` 未增加计数，其余已入账调用点不会 double-count。该修复与下述三参考控制流及 wrapping 账本一致；本次复核没有编译或运行测试。

**位置：** `swift-echo-server/Sources/internal.swift:881`，`cesAcceptorPacket` 的最后一个非超时失败分支。

**初次审查事实（保留发现证据）：** 当 `GetQueuedCompletionStatus(acceptor)` 返回失败、`OVERLAPPED == nil`、原生错误不是 `WAIT_TIMEOUT`，且没有匹配控制包时，Swift 原先仅调用 `cesAcceptorFail`。该函数（`:760`）报告已捕获的错误、发布 failure 并停止 admission，不修改统计。因此它最终退出 network/2，但 `/stats` 的 `network_errors` 比同一输入的三套参考少 1。Coordinator 只汇总 Acceptor core 账本（`Sources/server.swift:147`），不会补上此运行中失败。

**核实的共同参考：**

- C++ `cpp-echo-server/src/ces_engine.cpp:922` 至 `:926`：在相同的非超时 GQCS 失败分支执行 `++acceptor->network_errors`，随后发布 failure、stop。
- Rust `rust-echo-server/src/internal.rs:3745` 至 `:3751`：同分支先 `statistics.network_errors.wrapping_add(1)`，随后 `fail_admission`。
- Zig `zig-echo-server/src/internal.zig:1533` 至 `:1535`：同分支先 `core.network_errors +%= 1`，随后 `failAndStop`。

**已采用的最小修复：** 在 Swift 上述分支调用 `cesAcceptorFail` 前，对 `acceptor.pointee.core.statistics.networkErrors` 执行一次 wrapping 加法。保留就地捕获的 `error`、具名阶段、退出 2 和现有 stop/drain 路径；计数未放进通用 `cesAcceptorFail`，因为 AcceptEx、Socket 创建、配置和 context 更新的调用方已经各自入账。没有扩展故障矩阵或修改测试预期。

## 已核实的源码契约

以下索引保留初次完整源码审查时的行号；SR-S-01 四行展开使 `internal.swift` 的后续位置向后移动 4 行。关闭复核的当前准确位置见上节。

### 完整审查范围与职责边界

已读完 Swift Server 七个 `Sources/*.swift` 文件、`Package.swift`、`Tests/CESFaultDriver/main.swift`、四个 Swift Testing 文件，以及全部 ownership/safety Swift 用例；核对的是当前完整 WIP 重写和恢复增量，而非仅 `git diff`。读取了根 `AGENTS.md`、2026-10-14 剩余对齐规约及 `resume-server-report.md`、`reference-alignment-report.md`。Swift 基线仍为 `dbaad11322d45cebb55dcb99e0bb90a755cb33a8`，没有将该 WIP SHA 解释成已编译版本。

`types.swift` 与 `engine.swift` 无 WinSDK、Socket/RQ/OVERLAPPED 字段；`internal.swift:4` 至 `:316` 的 Connection、UdpEngine、AcceptorCore、TimerHeap 不读取原生 provider 账本。Core 的固定存储是冷初始化资源，状态决策没有按完成分配堆对象或使用动态协议分派。Connection 的无 outstanding 断言与 Rust 对应纯连接的共同 fail-fast 政策一致。生产初始化使用 checked/fallible 入口，`try!` 留在冷便利构造器。保持七个真实生产文件，Package.swift 为模块入口差异，不需要空文件。

### TCP 完成、取消、统计与 Timer

- `internal.swift:455`：Native post 在 provider 接受后才设置 `providerOperation`、`postedLength`、Worker 总账并调用 Arena `didPost`；立即拒绝返回完整已捕获 Failure，业务撤销交由 Engine。
- `internal.swift:501`：规范化完成检查 RequestContext 范围/步长、Owner、connection/request index、操作匹配、provider ownership 和实际 posted length。失败状态也经过相同检查。
- `internal.swift:529`：清除 provider operation、减 Worker 总账、Arena `didComplete`，随后才发 Engine completion Event。关闭 Socket/RQ 从不减 provider 账本。
- `engine.swift:97`、`types.swift:95`：成功完成即使处于 Closing 仍记 traffic；Closing 中取消不增加网络错误；非 Closing 的错误记一次。发送无进展/超过 echo 剩余量是连接网络错误；超过原生 posted window 在退休前退出 4。
- `engine.swift:126`：立即 post 拒绝只撤销本连接的业务请求，并执行连接级关闭/释放；Runtime 不把此网络拒绝升级成整个 Server failure。
- `engine.swift:151`：mayExit 除业务 lifecycle 之外要求 TimerHeap 空；`CESEngineSequenceTests.swift:79` 有空引擎、残留 Timer、移除 Timer 的正反对照。关闭 deadline 只在首次 close 设置；完成可退休最后一个连接并移除 Timer，缺失真实完成则进入具名 drain timeout。
- `internal.swift:594`：IOCP 与 CQ 仲裁有界；到期前做有限原生完成仲裁，再处理 Timer，不以伪完成抹平账本。

### Acceptor、Credit 与 CL-01

- `internal.swift:184`：returnSlot 只允许 Posted/Transit → Idle；deferRepost 只允许未停止时 Idle → Deferred。失败返回保持原状态。Runtime 同步拒绝、withdrawal、deferred repost 调用点均同时检查非 provider-owned。
- `internal.swift:748`：Stop 检查每项 `providerOwned ↔ Posted`，只关闭 Posted Socket 请求取消；不读取或关闭 Transit Socket。Transit Socket 在 Worker 接管/撤回后通过真实 ACK 返回；Deferred 通过其真实控制包退休。
- `internal.swift:867`：AcceptEx 完成身份、固定地址对齐、Owner、Index、Posted 与 provider-owned 全部有效，且 `cesRequireAcceptCompletionExtent(transferred)` 成功，之后才令 `providerOwned = false`。零 ReceiveDataLength 允许的 transferred 值只有 0；具名 guard 为 `AcceptEx completion exceeds posted range` / 13 / exit 4。
- `internal.swift:149` 与 `:796`：CL-01 策略 A 顺序为 stopping/failed/listener invalid → withdraw；健康 listener + invalid accepted socket → 立即 fail-fast；健康双 Socket → 正常 context/configuration/address/credit/handoff。withdraw 不产生新网络错误，invariant 不走全局 network/2。
- Swift 字面值 16 组独立真值表在 `CESEngineSequenceTests.swift:132`，与三参考 bit 表完全一致：bit0 stop、bit1 failed、bit2 listener valid、bit3 accepted valid，只有 row4 fatal、row12 handoff，其余 withdraw。
- `internal.swift:116`、`:549`、`:835`：reserve 包含在途 handoff；Worker stop withdrawal、RQ 创建拒绝、最终连接 release 各归还一次。容量满只 rejected 并回收 accept slot，不额外发布 handoff。ACK 前 Socket 为 Worker 独占访问；ACK 后 Acceptor 才复用。

三参考 CL-01 增量也已完整静态核对：

| 实现 | 纯判定 | 生产边界 | 实际 exit 4 证据 |
| --- | --- | --- | --- |
| C++ | `src/ces_engine_internal.cpp:10` | `src/ces_engine.cpp:774`，生产调用 `:866` | `src/ces_engine_internal.cpp:61` 的 `TerminateProcess(..., internal)`；internal 为 4 |
| Rust | `src/internal.rs:110` | `:3025`，handoff `:3758` | `src/native.rs:695` 的 `TerminateProcess(..., ExitCode::Internal)`；Internal 为 4 |
| Zig | `src/internal.zig:935` | `:943`，handoff `:1404` | `src/native.zig:342` 的 `TerminateProcess(..., 4)` |

三者 fatal 的准确输出均为 `AcceptEx handoff invariant failed: native_error=10038`，执行位置在任何该 handoff cleanup 前。Zig 当前已从旧 `failAndStop` network/2 改为真正 fail-fast/4，没有仅把 `.fatal` 枚举当作退出码证明。C++/Zig 正负驱动调用的是生产 require-disposition 边界；Rust 对应进程测试 `internal.rs:4359` 重执行该测试并以 10 秒 deadline 约束子进程，超时 kill/wait。该审查没有重跑这些测试。

### UDP 和通知排空

- `internal.swift:57`：每 Slot 的逻辑方向/outstanding/length 与 Native Slot 的 providerOperation/postedLength 分开；重复 post 不增账，错误方向完成不扣别的 Slot。
- `internal.swift:98`：10054 恢复 receive 和完整 payload capacity；零字节 Receive 仍生成零字节 Echo Send。Stop 后完成只退休，无 repost；立即 post 拒绝不清除其他 Slot 在途账本。
- `internal.swift:1065`、`:1086`：原生 post 接受后才记 provider/Arena 和 markPosted；Completion 检查真实 RequestContext/Slot metadata、provider ownership、posted extent 后先退休 Native/Arena，再发 Event。
- `internal.swift:1144`：两套总账和所有原生 Slot 都归零后才发 generationDrained，随后检查 mayRelease 与真实 Notify snapshot，再执行 release。
- Worker/UDP RIONotify 只在真实 outstanding 且未武装时调用；真实 IOCP 通知才能清 armed 和增加 deliveries。合法最终 gap 仅 0/1，outstanding timeoutWakeups 必须为 0；截止排空仲裁有 record/batch 上界。

### Join、资源边界和 Swift 所有权

- `server.swift:133`：先 Stop/Join Acceptor，向完整 constructed Worker 集合发 admission-closed 和 stop，再 Join ALL；之后才集中检查 Acceptor/所有 Worker、汇总账本/快照、销毁。constructed 与 started 分开，已初始化而未启动者仍经无操作 Join 和 cleanup。
- `internal.swift:683`、`:960`、`:1037`：Worker/Acceptor/UDP 释放函数内部重复 ownership 检查；Worker 关闭 CQ 后注销 Arena、释放页，再关闭残留 Socket/IOCP，最后释放固定 completion/context/notification 存储。Acceptor 检查 provider/live/Join 后才释放 Operation/Address 存储。
- `internal.swift:432`、`:738`、`:1045`：deinit 自身检查 outstanding、Join 和显式资源 teardown；不能依赖 Coordinator 唯一一处 guard 后隐式释放。
- `native.swift:427` 与 `:443`：CESRioArena release 和 deinit 都检查自己的 trusted provider ledger。传入 `release(0, 0)` 或省略 release 不会抹去 didPost 未退休引用；先 guard 再注销注册/释放页。
- `CESFaultDriver/main.swift:43`、`:71`：Worker/Acceptor 顺序负例把 Native record 放在栈上并假定为 HeapAllocation。若固定存储先被释放，HeapFree(stack) 会进入不同具名失败/崩溃，无法给出要求的 Worker/Acceptor ownership 阶段；因此具名边界确实证明 guard 先于该存储释放。各有合法 release 正向对照。
- Native Owner/Runtime/Configuration/FixedArray 为 `~Copyable`；配置 borrow accessor 保持唯一所有权。异步 identity 来自覆盖 Windows 借用期的固定分配；没有把局部 OVERLAPPED 交给异步 Provider。Swift noncopyable Optional、borrow/mutate accessor、strict-memory-safety、C ABI 的编译器接受性仍需统一真实 SwiftPM 编译证据。

### 进程故障与输出

`CESFaultDriver/main.swift:110` 的测试 adapter 先调用真实原始 RIODequeueCompletion，再且仅扣留首条实际 Status=995 的记录；不伪造完成、不调整生产 provider/outstanding 账本。扣留前以生产 cesReport 直接写 stderr 的 `fault real cancellation completion withheld failed: native_error=995`，随后由生产 drain timeout 结束。正例不扣留，只有内部 cancellationSeen 才允许 `:201` 打印 `e2e cancellation drained`。partial_startup 和 native worker 场景也先 Join 全部，再集中检查/释放。仅从源码可确认接线意图，实际观察 995 和进程时限是否通过仍以 PowerShell 原始日志为准。

最终统计字段与顺序在 `server.swift:34` 保持共同契约；TCP workers 使用实际创建的线程数，UDP 为 1；所有 traffic/汇总统计为 wrapping 算术。CES_DIAG_FILE 只在全部 Join/检查后写，写入失败不改变退出码。SO_UPDATE_ACCEPT_CONTEXT 与 Socket 配置故障先捕获自己的原生错误；后续关闭不会覆盖本次诊断。SR-S-01 已关闭，本次完整源码审查没有其他可核实的新增账本、释放顺序或 CL-01 阻塞。

## 后续裁定边界

SR-S-01 源码修复及定点静态复核已完成。根代理可按最新 SwiftPM-only 方案执行统一 format → Release → Debug 及既有原生故障/reset/所有权/safety/IR 门禁。保留每轮原始失败；当前报告不得被当作编译或运行成功证明。无新增性能结论，无建议扩充负载矩阵、增加后端或进行无关重构。此次 closure 复核仅核对 Acceptor 计数修复；SwiftPM-only 门禁与 interop 的真实 `--show-bin-path` 接线仍由根代理和脚本复审负责，不扩大本报告的源码结论。
