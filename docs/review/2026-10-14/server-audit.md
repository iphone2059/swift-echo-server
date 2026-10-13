# Swift Server 对齐只读审查（2026-10-14）

本报告只审查源码、已有 Git 历史和规约；未修改仓库源码，未 fetch、编译、测试、提交或推送。根 AGENTS.md 的 main-only、全部源码完成后统一验证、先 Join 全部线程再集中检查释放边界规则适用。文中行号是审查时旧 Sources 的位置，迁移后应更新。

冻结的参考版本：

- Swift：`bcd4d5b2fe33878028ae820dc618cb298924b910`。
- Rust：`ac8bdee80bd89731f908ef2da84baeefc92749d4`；核心修复 `38f84d2`（runtime/failure）、`0ed84a1`（pure-core/event contract）、`0080695`（UDP page budget/native acceptor）、`9fd187b`（RIO lifecycle）。
- Zig：`28b471719273643681ad44ac9083099888d05e4e`；核心修复 `28b4717`（runtime/failure）、`138c68b`（pure UDP/event contract）、`c502f95`（post ownership）、`6841774`/`8550dc0`（stop/handoff ownership）、`56e0ef6`（UDP ledger/statistics）。
- C++：`68d808503899abd0be1d6bca87795b3eca226ec7`；前序 `63cee82`（RIO slot isolation/page-rounded UDP budgets）。

## 1. F1 物理文件与职责迁移

Swift 当前有 15 个 Sources 文件：14 个 CESServerCore 文件和 main.swift。Rust/Zig 各有 8 个。迁移应建立以下 8 个对等文件，保留现有 SwiftPM 两 target 拓扑；不要为了拼凑文件数量新增业务层。

| Rust / Zig | Swift 对等文件 | 现有 Swift 内容来源与目标职责 |
| --- | --- | --- |
| main.rs / main.zig | main.swift | 保留进程入口、CLI 诊断、控制台回调注册和退出码 |
| lib.rs / root.zig | lib.swift 或 root.swift | 真正的模块导出/可见性边界；Swift 无模块索引语法时记录语言声明适配，不能放空文件或整段业务转发 |
| contract.rs / contract.zig | contract.swift | CESContract；参数、容量、page rounding、offset、通知转换等纯契约函数 |
| engine.rs / engine.zig | engine.swift | 新建独立纯 TcpEngine，连接集、free list、TimerHeap 使用、业务 outstanding、Lifecycle、Statistics 与 Action；移出 CESEngineWorker 的业务判断 |
| internal.rs / internal.zig | internal.swift | Connection、AcceptorCore、AdmissionCredits、UdpEngine、TimerHeap，以及 TCP worker/acceptor/UDP runtime；文件内明示纯模块和 runtime 模块边界 |
| native.rs / native.zig | native.swift | CESNative + CESOwnership + CESFailure 的原生资源和诊断；Socket/Handle/Arena/RIO CQ/RQ、固定地址存储和 Win32 调用适配 |
| server.rs / server.zig | server.swift | CESEngine 的 Winsock/RIO 装配与协议分派；协调器入口、控制对象；Rust coordinator 当前放 internal::worker::tcp，而 Zig放server，需记录真实对应关系 |
| types.rs / types.zig | types.swift | CESTypes + CESConstants + CESEngineInternal 的共同 enum/data/Lifecycle/Failure/Statistics/NotifySnapshot；不得保留 WinSDK/native handle 依赖 |

原 CESEngineTCP/Worker/Acceptor/UDP 和 CESEngineInternal 不应简单合成一个巨大执行函数：保留 Connection、TcpEngine、AcceptorCore、UdpEngine、Transport/Runtime 的独立逻辑身份。同模块跨文件是 Swift 语言差异；对应实体与接口必须登记。若 8th module-index 文件在 Swift 语义上确实不需要，应按规约记录语言声明例外，不能虚构业务职责。

## 2. P0 所有权与释放边界

### 2.1 每 slot 独立 RIO 注册

旧 `CESEngineWorker.swift:451` 对整个 TCP arena 只注册一次，所有连接共享 BufferId，Offset 为全 arena 偏移；旧 `CESEngineUDP.swift:95` 也让所有 UDP slots 共用 BufferId。Rust `native.rs:907` 的 Arena 明确采用一个 VirtualAlloc + 每固定 stride slot 独立 RegisteredBuffer；Zig/C++一致。参考实现注释指出 RIO send 占用整个 registration，不能由并行 slot 共用。

可执行改动：native.swift 创建独占 Arena，固定 slot registration owner 数组；TCP slot BufferId 独立且本地 Offset=0 或 sendOffset；UDP slot payload Offset=0、remote Offset=payloadCapacity，共享该 slot 独有 BufferId。初始化失败先撤销已经注册的 slots，再释放 pages。关闭/注销/arena 释放顺序不得依赖 struct 字段隐含析构顺序。

### 2.2 Transport provider 账本与字节边界

旧 TCP 请求只有 connectionIndex/operation，Connection.outstanding 同时承担业务和原生账本；旧 UDP slot 用 operation/outstanding 混合业务状态和原生资源。缺少 providerOperation、postedLength、独立 providerOutstanding。

可执行改动：每原生 slot 保留可选 providerOperation、postedLength；成功提交后才登记 provider ownership；失败提交不得删除旧 ownership。处理 Completion 必须依次验证 context 身份/范围/对齐、provider ownership、操作方向、`BytesTransferred <= postedLength`，核销 Transport provider ledger，再生成共同 Completion/Event 交给 Engine。同一 slot 不得重用仍 provider-owned 的请求和 descriptor。不要把 closeSocket 当作核销操作。

旧 TCP `releaseConnection`（Worker:32）无内部 guard，且直接把 outstanding 写0；这不满足“任意释放调用方不能绕过所有权检查”。每 slot release 内部先验证 providerOperation为空以及业务outstanding=0，再释放、返还 AdmissionCredit。Engine 中 close→closing 后仍等待 Completion；Transport保留contexts/buffers。

### 2.3 全线程 Join 屏障

旧 TCP:77 直接 `cesDestroyAcceptor`（Join+release），旧 TCP:84 对每个 worker 逐个 `cesDestroyWorker`（Join+require+release）。这与 AGENTS.md 的全线程屏障不符。

可执行改动：拆为 stop、join、requireRelease、destroy 四阶段。顺序是：Stop/Join Acceptor → 向所有已启动 Worker 发布 AdmissionClosed → Stop 所有 Worker → Join 全部 Worker → 集中检查 Acceptor/全部 Worker → 按顺序 release。Acceptor storage/port/table 应保留到全 Worker Join 和集中检查之后。每 destroy 函数重复其内部 requireRelease，防止其他调用方绕过。需分别跟踪 initialized / actual thread-created / ready，不将“初始化返回失败但线程已存在”的 worker 漏出 stop/Join 集合。

旧 `cesDestroyAcceptor`（Acceptor:348）没有 live slot/transit/OVERLAPPED ownership guard，直接清理 operation sockets/storage。需在内部释放任何原生资源前检查 AcceptorCore liveCount/postedCount/transit/deferred，以及仍被 provider持有的 AcceptEx records。

旧 Worker destroy 只在 ready时检查 active、timer与notification；应先无条件检查 provider ledger/rioOutstanding；曾运行者还检查 lifecycle、freeCount==slotCount、credits完整归还。Acceptor 与 Worker 的任一 fail-fast guard 都要在资源释放前执行。

### 2.4 drain 期限与完成/计时优先级

旧 TCP closeConnection删除 timer（Worker:43），没有 closing drain deadline；UDP/Acceptor也没有5s drain期限。若 provider丢失 Completion，Join/UDP loop将一直等。参考 Connection.close_at给closing state设置5s deadline，UDP/Acceptor也记录首次 drain deadline，不在重试时续期。

可执行改动：所有关闭路径统一建立5s drain期限；到期先在有限预算下处理已经排队的IOCP packets和CQ completions，再判仍outstanding并以 `DrainTimeout(stage,1460)` fail-fast。Worker 的普通timeout前也必须完成这轮有限原生仲裁，避免已完成但notification稍迟的I/O被错误当timeout。参考Rust Worker runtime:2406–2502 的预算是slotCount + acceptOperationCount(maxWorkers) + 2，CQ最多slotCount条；Zig/C++有对应步骤。不要添加无限poll或无界while-drain。

### 2.5 通知生命周期

旧 Worker:349 在退出时打印 notification-unarmed precondition，destroy:519又强制!notificationArmed；UDP:299也输出该precondition。参考允许所有RIO请求已完成后仍有一条真实RIONotify待交付（arms-deliveries∈{0,1}）。Notification不决定业务可退出性。

可执行改动：types.swift增加NotifySnapshot；运行时记录arms/deliveries/timeoutWakeups。只有 outstanding>0且未arm才arm。释放前providerOut=0、完整归还；允许最多一个合法待交付packet。关闭CQ后notification OVERLAPPED、completion key和slot identity仍保持有效直到IOCP关闭，再释放其固定地址存储。旧 Worker destroy 在 port reset 之前释放 notification/requests/connections，不满足此地址存活顺序。不要伪造notification或将armed清零冒充交付。

## 3. 纯 Engine/Event/Action/Lifecycle

共同链必须为 `Transport → Completion/Event → Runtime → Engine → Action → Runtime → Transport`。当前 `processResult`、`postReceive`、`postSend`、`processDeadlines`、`takeSocket`同时直接修改业务状态、调用RIO、统计并释放，无法独立替换Transport。

可执行改动：

- types.swift 定义 `Completion(index,operation,status,bytes)`、`Event(completion,postFailed,stop,admissionClosed,generationDrained)`、Failure metadata和Lifecycle；TCP特有Event可补now/timeout/admit参数，保持与Rust/Zig实际接口对应。
- engine.swift 定义纯 TcpEngine；Action/Step为receive(index,deadline)、send(index,offset,length,deadline)、close(index)、release(index)。Engine只拥有Connection、timer、free list、逻辑outstanding与Statistics。所有WinSDK句柄/slot/provider账本移出。
- internal.swift 纯Connection状态集为 idle、receiving、sending、closing、released；原两个bool active/closing不足以直接审查状态集合。
- internal.swift 独立UdpEngine：SlotState(direction,payloadLength,outstanding)、phase/closing/failed/failure/statistics；`Post(index,operation,payloadLength)`/fatal/none Action必须携带完整负载，Runtime不得重新读取native slot业务字段“补决策”。
- UdpEngine仅在成功提交后 markPosted；Completion核销slot逻辑outstanding；postFailed只标失败并进入draining；Stop停止repost；GenerationDrained只有Transport全部账本归零后发布，Engine也检查closing和outstanding后进入stopped。
- AcceptorCore拥有idle/posted/transit/deferred状态和事件转移，runtime owns AcceptEx/socket/output records。
- WorkerPhase加quiescing（starting/running/quiescing/admissionClosed/draining/stopped）；WorkerLifecycle加rioOutstanding。workerMayExit检查admission barrier、active=0、pendingHandoffs=0、rioOutstanding=0；notification不成为退出前提。
- TimerHeap移入internal.swift纯timer子模块，保留固定容量、deadline/index稳定tie-break、empty=INFINITE及有限上限；其算法当前基本可复用。

## 4. TCP/Acceptor行为和容量

### AdmissionCredits 与容量感知分流

旧 Acceptor:217 仅固定round-robin，Worker:242满容量后静默关闭；参考每Worker有原子AdmissionCredits，包含尚未消费的handoff reservations。可执行改动：从rotation起逐worker尝试reserve，成功者才接socket；全部满则计rejected并重post AcceptEx；归还条件是对应connection最终release、RQ初始化失败、拒绝/撤回handoff。不可只读freeCount再handoff，否则连续完成会overbook。

旧 Accept window=min(workers*32,1024)（Acceptor:302），共同规则是clamp(workers*2,8,128)。自动Worker cap旧为32（TCP:8），共同为64；`/threads 0`表示auto。TCP memoryShare旧简单除count，不按pages分配余量；需复用page-aware `workerMemoryBudget(memory,count,index,page)`并对rounded arena预算审核。UDP同样用page-rounded capacity before transport init。

### Recoverable/error/stop顺序

旧 recoverable（Acceptor:58）只有ERROR_NETNAME_DELETED，共同还包括WSAECONNRESET和WSAECONNABORTED。参考还有有限同步retry并转deferred repost packet，避免acceptor被同步reset无限占用。

旧 successful AcceptEx完成在stopping时仍配置socket并handoff；应由Core先决定drop/none，取消只处理真正posted slots，不取消transit handoff，更不能在stop时先清transit socket。Worker收到被withdrawn的invalid socket时根据stopping/failed disposition处理，而非无条件`server accept handoff socket` fail-fast。每native完成/ack身份和state验证之后再转移，所有control post失败fail-fast。

旧 `contextUpdated`后无条件执行socketConfigure（Acceptor:203）；参考context更新失败会静默计networkError并stopAdmission，不再configure；socketConfigure失败只保留一个其自身诊断，再stop，不重复报告。native/Winsock error必须在对应失败API之后立即捕获，不能被CloseHandle/closesocket或后续setsockopt覆盖。

旧CESNative明确不加载GetAcceptExSockaddrs、Acceptor也不调用（Native:52、Acceptor:214），但Worker:264注释错误地声称此前已验证。共同runtime会加载、获取并检查地址范围/长度/AF_INET，再允许handoff；应恢复对应native适配和校验，删除相矛盾注释。

Acceptor需完整ready/startupOK发布，保证pre-post全部成功或失败状态已经发布再让coordinator进入run；partial startup也要保留并Join线程。当前cesInitializeAcceptor线程创建即返回，无ready barrier。

## 5. UDP可观察行为和确定性缺陷

旧 UDP:221 先无条件增加receives/sends，失败/取消Completion被当traffic；共同Completion总数总加，但traffic与receivedBytes/sentBytes仅status==0增加，closing后的成功Completion照样记traffic，closing后的取消不计networkError。非closing的失败（含recoverable reset）计networkError；post失败也计networkError。

旧 UDP:230 reset仅将operation变receive，未恢复payload.Length。短echo发送产生WSAECONNRESET后，会拿旧短Length再次receive，造成后续大datagram容量不足。纯UdpEngine在recoverable reset之后明确payloadLength=payloadCapacity；Runtime据Action提交完整receive。

旧 UDP在每一bounded drain batch末读取stop/run deadline（UDP:275），参考在已取得notification时先完成其有限CQ drain再进入外层control arbitration。需复制共同偏序，不能只因端到端一般成功就忽略这条确定性差异。

## 6. 统计/stdout/诊断/错误分类

共同Statistics字段为accepted、completions、receives、sends、receivedBytes、sentBytes、bytes、networkErrors、rejected；旧仅前五字段（Internal:26）。所有counter用wrapping uint64语义，旧TCP completion/receive/send用普通`+=`，溢出会trap，应统一`&+=`。

旧TCP `processResult`（Worker:134）在closing时提前返回，漏记shutdown中成功的receive/send/bytes；应核销后先按native成功与否记账，再由Connection状态机决定不repost。有效send completion却0字节或超echo余量属于connectionNetworkError；native超过postedLength则是invariant fail-fast，两者不可混同。RQ创建拒绝计networkError，capacity refusal计rejected，stop拒绝不计capacity error；acceptor startup failure若domain非allocation也计networkError。

旧stdout有每worker行且TCP/UDP两套旧terminal字段（Engine:8/23），共同只有aggregate final：

`final protocol=... elapsed_ms=... workers=... accepted=... active=0 outstanding=... completions=... receives=... sends=... received_bytes=... sent_bytes=... bytes=... network_errors=... rejected=... MiB_per_sec=...`

workers使用实际启动线程数，UDP为1；elapsed rate guard为至少1ms。成功run无/stats不得输出旧precondition诊断。Notify diagnostics按参考环境控制开关输出join后的快照，不改变stdout。

types.swift增加FailureClass(network,invariant,drainTimeout)、FailureDomain(win32,winsock,allocation,invariant)、stage/code。Transport post返回完整Failure供Runtime生成postFailed Event；不得以report+Bool悄改失败状态来丢失元数据。Network post拒绝终止connection/UDP按共同策略；所有权invariant与drainTimeout必须在任何释放前fail-fast退出4。

旧 `cesReport`用signed Int32插值；共同原始native_error按u32位模式输出；RIONotify WSAEALREADY要用`RIONotify duplicate arm`独立stage，其他code保留原值。Console登记失败共同文本为`SetConsoleCtrlHandler failed: <u32>\n`而非通用native_error报表。wide argv失败共同network退出2，旧main.swift返回internalFailure=4。需与公共CLI审查统一。

## 7. 分配、Swift安全与成本风险

- 当前采用~Copyable、UniqueArray、borrowing/consuming、固定地址CESPinnedStorage的方向可保留；不要改成class/any protocol或Task/actor来表达Engine/Transport。
- production workers、acceptor和UDPslots用`UnsafeMutablePointer.allocate`，TimerHeap/owner数组使用UniqueArray reserve/append；这些无法报告OOM为共同Failure.allocation。参考Rust近期修复使初始化分配均fallible。可用Win32 HeapAlloc-backed独占固定容量storage，处理extent overflow、对齐和已初始化前缀rollback；不能让合法大容量OOM变运行时trap而声称failure parity。
- CESSharedControl/CESFailureFlag是shared class，只在cold startup建立；热路径borrow访问器与方法参数要检查retain/release/独占成本，保持固定批缓冲，不每post构造Array或闭包box。Native线程pointer必须稳定到全Join之后。
- Console handler当前Mutex保护class publication；参考回调是原子stop store且无lock/分配。共同控制对象可固定地址持有到handler卸载及线程join，回调仅原子store；严格并发安全说明必须覆盖正在执行的回调和卸载重叠。
- SwiftNative record布局不可凭声明字段顺序假设C ABI；现有MemoryLayout.offset guard以及范围/identity checks应保留，真正Windows借用的OVERLAPPED/RIO_BUF存储与业务~Copyable aggregate隔离。
- 迁移完成前应静态检查engine.swift/types.swift无WinSDK、RIO、HANDLE/SOCKET，纯Engine不读取Transport.slot/provider ledger/OVERLAPPED；runtime statically dispatched，native资源地址与borrow不跨临时view生命周期。

## 8. 后续验证清单（本次未运行）

全部Swift源码/架构/静态复审完成后再按根约定统一format→Release→Debug，不能修改PS1或既有预期迁就实现。需覆盖的已有共同契约输入：

- TCP receive→partial sends→receive、zero receive关闭、failed post、timers、closing成功/取消Completion、duplicate completion、超posted range；检查Actions与Statistics快照。
- UDP zero datagram、短datagram echo→reset→full-capacity receive、send reset、fatal completion、post拒绝不归零旧work、Stop后不repost、GenerationDrained premature拒绝/合法正向对照。
- AdmissionCredits连续burst不overbook、all-full拒绝账本、pending accept同步成功/WSA_IO_PENDING/三类recoverable reset、stop排在completion前、transit ack及Deferred重post。
- 5s drain边界内真实Completion优先、pending notification gap=1合法、gap>1/timeoutWakeups损坏拒绝；所有fault子进程有界等待。
- 集中Join屏障、destroy内部所有guard及正向对照、“先释放会触碰非堆地址”的顺序证明；partial worker/thread startup失败仍Join全部存活线程。
- page-rounded budgets、slot独立BufferIds、本地Offset/remote address bounds、标准usage与统计字段、error domain/code/diagnostic次数、exit码。

风险最高的实现切片是Arena slot注册与Transport账本、Acceptor跨线程socket/credit移交、全线程Join和notification地址保活。这些必须先完成源码和静态论证，然后才可开始正式性能基线。
