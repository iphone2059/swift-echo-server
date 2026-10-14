# 当前行为与语言表示差异

本文描述 2026-10-14 恢复对齐后的源码事实。实际 Release/Debug 门禁与最终二进制验收另行记录；历史暂停记录 [REVIEW_CHECKPOINT_2026-10-14.md](REVIEW_CHECKPOINT_2026-10-14.md) 保留原样。

正常协议、参数范围、AcceptEx 接入、Winsock RIO 数据通路、IOCP 线程、停止屏障、统计字段与退出码采用共同 `echo-binary-contract-v1`。程序名为 `swift-echo-server`，只实现服务端。

## 分层和固定地址

- `CESTcpEngine`、`CESConnection`、`CESUdpEngine`、`CESAcceptorCore` 拥有业务状态、逻辑 outstanding 和 Action。原生 Transport 拥有 socket、RQ/CQ、OVERLAPPED、providerOperation 和 postedLength；完成先核算原生所有权，再交给纯引擎。
- `Sources` 保持七个生产文件；SwiftPM 的真实 target 声明在 `Package.swift`，是 Rust `lib.rs` / Zig `root.zig` 的语言例外。
- Worker、Acceptor、UDP 的原生记录与通知使用固定地址 `CESPinnedStorage`。Win32 `HeapAlloc`、checked extent 与初始化后才公开的固定数组承担主要元数据分配；原生记录的字段地址由 `MemoryLayout` 求得。
- 一个 VirtualAlloc arena 内，每个并发 Slot 独立注册 RIO BufferId。TCP descriptor Offset 为 Slot 内发送偏移；UDP payload 与 remote address 在本 Slot 独有注册中使用局部偏移。
- 独占 owner 使用 `~Copyable`、借用访问器和显式释放；RIO 函数表按值保存。没有热路径动态 protocol、Task/actor 或每 Completion 新建数组。

## 停止、完成与移交

- 关闭 socket 只请求取消。providerOutstanding、providerOperation 和 arena 私有 provider 账本只在收到并核算真实完成时退休；同步投递拒绝只回滚未交给 Provider 的逻辑请求。
- TCP/UDP 通知排空使用最多 64 批的有限预算。到期裁决前还有按 Slot 数界定的 IOCP/CQ 完成优先处理；首次 Close 锚定五秒宽限，不随重试延长。旧文档称 C++ 无界排空、Swift 独有 64 批策略的描述已过时。
- `RIONotify` 在原生在途请求存在且未武装时投递，不合成通知。释放允许最多一条真实未交付通知；CQ 和 IOCP 都关闭前，通知与完成身份存储保持有效。
- 协调器先停止并 Join Acceptor，再向所有已启动 Worker 发布 AdmissionClosed 和 Stop，Join 全部 Worker，集中检查全部释放条件，最后销毁。部分启动失败也包含已经创建但未宣告 ready 的线程。每个 destroy/release/deinit 保留内部所有权 Guard。
- Acceptor Stop 校验 `providerOwned` 与 Core `Posted` 一致，仅关闭仍 Posted 的 accepted socket。Transit 属于已经发布的 Worker 移交，Acceptor 等 ACK；Deferred 等已排队的控制包。Credit 在拒绝或连接最终释放时恰好归还一次。
- AcceptEx 完成使用 `GetQueuedCompletionStatus` 的结果与紧邻读取的原始错误，不再二次查询 `WSAGetOverlappedResult`；请求接收长度为零，非零完成字节在退休 Provider 前 fail-fast。成功接入依次执行 SO_UPDATE_ACCEPT_CONTEXT、socket 配置、GetAcceptExSockaddrs 地址校验、Admission Credit 和 Worker 发布。
- 已统一健康状态异常政策 A：Stop、全局 Failed 或无效 Listener 撤回；健康 Listener 下无效 Accepted Socket 以 `AcceptEx handoff invariant` / 10038 退出 4。普通取消撤回不新增 Network Error。
- 三种可恢复 AcceptEx Reset（64、10054、10053）只重投该 Slot；连续四次同步拒绝后排队一次 Deferred Repost。

## 统计、诊断和错误

- `/stats` 只输出 aggregate final 行：protocol、elapsed_ms、workers、accepted、active、outstanding、completions、receives、sends、received_bytes、sent_bytes、bytes、network_errors、rejected、MiB_per_sec。TCP workers 是实际创建的线程数，UDP 为 1；速率分母至少一毫秒。
- 成功完成在 Closing 时仍记录 traffic。失败/取消都记录 completion，仅未 Closing 的失败增加 Network Error；bytes 是成功发送字节。UDP 10054 恢复完整接收容量，零字节 datagram 仍原长回显。
- TCP RIO Post 拒绝终止并结账该连接；UDP Post 拒绝进入整 Socket Drain，但保留其他 Slot 的在途请求。Provider 所有权损坏和 Drain Timeout 退出 4，不能伪装为网络失败。
- Native 错误在 API 失败点捕获。SO_UPDATE_ACCEPT_CONTEXT 失败按三个参考实现的现行共同政策静默计 Network Error 并停止接入；socket 配置失败只输出一次具名诊断。
- `native_error` 采用当前 C++/Rust/Zig 一致的 signed Int32 展示。历史审查中 u32 展示的判断与当前三种源码不符，不据此改变实现。
- `CES_DIAG_FILE` 记录停止后的通知快照，不改变 stdout 或退出码；TCP 在全 Worker Join 后写入，UDP 在排空和释放检查后写入。

## 语言与验证边界

- `try!` 便利构造器供冷路径契约测试使用；生产 TCP/UDP/Timer 初始化都使用可失败的 checked 构造器。原生分配失败保留 Failure；Swift class、String、Foundation 冷路径分配仍属于运行库分配边界。
- 共享控制、失败标志和 Admission Credit 使用 Atomic；控制台回调仅发布 Atomic Stop，进程控制对象保留到进程结束。原生线程与 socket 移交依赖 Win32 就绪、Join 和 IOCP 发布/ACK 屏障。
- StrictMemorySafety、不可复制 Optional 的消费/析构、`@c` 的 Windows 回调签名和优化后 ARC 成本必须由实际工具链验证。源码审查不替代编译、安全或性能证据。
- `/memory` 限定注册 arena 预算，不是进程总内存上限。Windows x64、实际构建的 Swift 工具链/SDK/动态运行库是交付环境；历史 Swift 6.4 数据不代表新的开发快照产物。
