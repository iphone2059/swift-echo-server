# 与 C++ 基线的差异

正常协议行为、参数范围与诊断、AcceptEx 接入、RIO 数据通路、IOCP 工作线程、admission-closed 停止顺序、UDP 槽位复用、退出码与统计字段与 `cpp-echo-server` 一致。产品和帮助中的程序名改为 `swift-echo-server`；本仓库不实现客户端。

## 所有权与布局

- 工作线程配置是 `~Copyable`，连接表与 RIO 请求上下文表由 `CESPinnedStorage` 保持固定地址，socket 的所有权在 `UniqueArray<CESSocketOwner>`，接受操作的地址缓冲区由接受器唯一持有。
- `AcceptEx` 的 `OVERLAPPED` 与 operation 记录同址：投递前校验其字段偏移为 0，完成包地址先按分配范围与步长校验，再映射回记录；工作线程收到的 handoff 键同样按范围与对齐校验。
- RIO 注册与 CQ owner 保存函数表副本，避免函数表裸指针的寿命依赖。停止标志与失败标志使用 `Synchronization.Atomic`，控制对象在所有线程 join 前保持存活。
- 原生字段地址由实际 `MemoryLayout` 偏移计算；不把 Swift 临时 inout 地址交给异步 API。
- UDP 槽位表与通知 `OVERLAPPED` 使用显式固定分配并在作用域退出时释放，等价于基线的 `HeapAlloc` + owner；释放顺序为 CQ、通知、注册、槽位、arena、socket、端口。
- 完整引擎没有声明 `@unchecked Sendable`，也不使用 Swift Task/actor 替代原生工作线程。

## 停止响应与排空

- TCP 与 UDP 的单次 CQ 排空最多连续处理 64 个批次，然后检查停止标志与 `/w` 期限并返回主循环；基线一直排空到 CQ 为空。饱和流量下基线的停止包可能长时间得不到处理，Swift 版本让停止响应保持有界（实测满速洪泛下 ≤1.1 s 完成受控停止），排空内部一旦观察到停止或到期就关闭 socket、停止重投。未取走的完成仍留在 CQ，由下一次 `RIONotify` 通知取回。这是唯一有意保留的数据面时序差异。
- 通知改为**惰性**：只有在途请求存在时才武装 `RIONotify`（TCP 判据为活动连接数非零，UDP 为 `outstanding != 0`），收到投递即取消武装，排空后若仍有在途请求再由主循环重新武装。因此空闲引擎不持有挂起注册，释放路径不再需要合成 IOCP 包或“放弃注册”迁移；两端在销毁 CQ 之前都会校验注册已解除，若仍为武装只报告诊断而不掩盖。
- 工作线程退出仍要求 stop 与 admission-closed 都已处理且活动连接为 0；join 后校验 phase、活动连接、handoff、通知状态与定时器堆都满足释放前置条件。
- 接受路径不做第二次状态查询：`GetQueuedCompletionStatus` 的成功/失败与 `GetLastError` 直接决定 AcceptEx 结果，不再调用 `WSAGetOverlappedResult`。对端地址在 acceptor 中只作为 AcceptEx 的输出缓冲区存在：echo 服务不消费它，因此既不在 worker 调用 `getpeername`，也不再解析 `GetAcceptExSockaddrs`（该扩展函数指针不再加载）；每新连接少三次调用，行为不变。
- 启动失败的错误码在调用点就地捕获（`WSASocketW` 用 `WSAGetLastError`，`CreateIoCompletionPort`/`VirtualAlloc`/`CreateEventW` 用紧邻调用读取的 `GetLastError`），不再依赖稍后读取时仍有效的线程 last-error。
- 客户端在 `AcceptEx` 完成前重置连接（`ERROR_NETNAME_DELETED`）按“连接级失败”处理：只关闭该 operation 的 socket 并重投 `AcceptEx`，监听与进程继续；其余完成错误仍保持基线的致命分类。这一条**不是移植差异**：`cpp-echo-server` 已同步修复（`ces_engine_accept_error_is_recoverable`），两侧都跑 `tests/ces_reset_storm_tests.ps1`（400 次预接受 RST + 随后正常回显 + 干净退出）。
- 已接受的 socket 通过 operation 记录的裸值转移所有权：acceptor 在 handoff 前释放自己的 owner，worker 用该裸值构造 `CESSocketOwner` 接管，acceptor 在 ACK 与销毁时回收未被接管的残留 socket；worker 不再访问 acceptor 的容器。

## 输出与诊断

- 逐工作线程统计只在该工作线程确实创建过线程时输出。基线在启动失败路径上也会为从未启动的 worker 打印一行；Swift 版本只在 `/stats` 且线程已创建时输出。正常路径完全一致。
- 参数解析、帮助文本、`final` 汇总字段与数字格式（POSIX locale，两位小数）与基线一致；`/q` 与基线一样不改变服务端输出。
- 启动容量检查在协调器中完成（基线在工作线程初始化内完成），退出码同为 2，stderr 沿用相同的阶段名；因此容量不足时不会创建任何工作线程。

## 分配与环境边界

- `VirtualAlloc`、`HeapAlloc`、Winsock/RIO/线程/句柄 API 的失败按基线阶段报告。`UniqueArray`、Swift 类及引擎元数据使用标准库分配；真正耗尽这些分配时 Swift 运行库可能终止进程，无法保证映射到基线的可恢复退出码。
- `/memory` 是注册 arena 的总限额（按工作线程均分），不是整个进程内存上限。
- 必须提供匹配 Swift 6.4 的动态运行库；Windows x64 以外的平台不在此版本范围内。
