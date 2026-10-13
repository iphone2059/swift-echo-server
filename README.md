# swift-echo-server

> 2026-10-14：按用户要求暂停并提交 WIP 审查快照。本轮尚未运行完整格式化、编译和测试门禁；待完成事项见 [暂停交接](docs/REVIEW_CHECKPOINT_2026-10-14.md)，更新规范见 [跨语言规范](docs/CPP_Rust_Zig_Swift_Refactoring_Spec_v2.0.md)。

Windows x64 Swift RIO Echo 服务端。数据面保持 Winsock RIO，完成队列通过 IOCP 通知；没有普通 send/recv 或其他后端。共同契约为 echo-binary-contract-v1。

Sources 下直接包含七个 Swift 文件，与 Rust/Zig 业务文件职责对应：

| 文件 | 职责 |
| --- | --- |
| main.swift | CLI、控制台 handler 注册和退出码 |
| contract.swift | 参数、容量、page rounding、offset 与通知转换契约 |
| types.swift | Event、Completion、Action、Failure、Lifecycle、统计数据 |
| engine.swift | 不读取原生 I/O 状态的纯 TcpEngine |
| internal.swift | Connection、AcceptorCore、UdpEngine、TimerHeap，以及 Worker/Acceptor/UDP Runtime 和 Transport |
| native.swift | Win32/Winsock、固定地址存储、Socket/Handle/RIO/Arena 独占资源与诊断 |
| server.swift | 装配、协调器、全线程 Join 屏障、最终统计 |

Swift 自动形成模块，Rust lib.rs 与 Zig root.zig 对应 Package.swift 的语言声明例外。CESServerCore 和 swift_echo_server target 用互斥 sources/exclude 清单共享扁平 Sources，没有同名子目录或占位索引文件。

运行链是 Transport → Completion/Event → Runtime → Pure Engine → Action → Runtime → Transport。原生完成首先验证 context 身份、方向与已提交字节范围，核销 provider 账本后才交给 Engine。取消 socket 不清空在途账本。TCP/UDP 每个固定 stride slot 独立注册 RIO BufferId；负载在原注册区域回显。

TCP 接入窗口为 clamp(workers * 2, 8, 128)。原子 AdmissionCredits 同时覆盖已连接会话和在途 handoff，容量感知分流避免可用 worker 被跳过。AcceptEx 支持同步完成、pending、三种连接级 reset、有限同步重试及 deferred repost。

停止顺序：停止并 Join Acceptor，向全部 Worker 发布 AdmissionClosed/Stop，Join 全部 Worker，集中检查释放不变量，再释放。每个释放入口重复检查；arena 还持有私有 provider 账本，传零无法绕过。缺失最终完成在固定 5 秒 drain grace 后 fail-fast；到期前先有限处理已排队的 IOCP/CQ 完成。释放允许一条合法待交付 RIONotify，OVERLAPPED/context 地址保留到 CQ 和 IOCP 都关闭之后。

构建需要匹配的 Windows Swift 工具链、SDK 与运行库，无第三方 Swift 包。

```powershell
swift build -c release --product swift-echo-server
$bin = swift build -c release --show-bin-path
& "$bin/swift-echo-server.exe" /p tcp /s 7000 /threads 8 /stats
& "$bin/swift-echo-server.exe" /p udp /s 7000 /k 256 /stats
& "$bin/swift-echo-server.exe" /h
```

/threads 0 为自动 TCP worker 数（1..64）；UDP 只使用 1，拒绝显式大于 1。/w 0 表示不设期限。/memory 检查 page-rounded arena 预算；UDP 还要求 cq >= depth * 2 和完整 datagram 容量。/h 仅省略必需协议检查，不屏蔽错误参数或非法容量。

/stats 仅输出 aggregate final 行，字段依次为 protocol、elapsed_ms、workers、accepted、active、outstanding、completions、receives、sends、received_bytes、sent_bytes、bytes、network_errors、rejected、MiB_per_sec。关闭期间成功完成仍计流量，失败/取消仅计 completion；关闭后的取消不计 network error。bytes 为成功发送的字节。CES_DIAG_FILE 可记录停止后的通知快照。退出码：0 成功、1 参数无效、2 网络/准备失败、3 保留、4 不变量或 drain 超时。

完整门禁按 format.ps1 → build_release.ps1 → build_debug.ps1 执行，包含 CTest、非空 Swift Testing、所有权/安全编译正反例、进程/互操作/reset storm 与有界故障子进程。Tests/CESFaultDriver 为独立测试产品；生产 CLI 没有故障模式。FaultDriver 包含完成身份/长度、真实 Worker IOCP 停止与缺失完成账本、partial startup、释放正向对照和栈地址释放顺序证明。

CESFixedArray 采用 fallible HeapAlloc、checked extent、固定容量及有界访问，完整初始化后公开，仅析构已初始化元素。Worker/Acceptor/UDP 热路径不扩容、不新增动态协议分派、Task 或 actor。正式 E0 与性能排名仍需另行冻结发布产物、工具链、负载和测量预算；功能门禁不能代替性能结论。
