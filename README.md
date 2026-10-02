# swift-echo-server

Swift 6.4 重写的 Windows x64 RIO Echo 服务端。参数、退出码、统计字段和收发路径沿用 C++ 服务端：数据面只有注册 I/O（RIO），RIO 完成队列通过 IOCP 通知工作线程，不存在普通 `send`/`recv`、数据面事件轮询或其他回退后端。

## 架构

- TCP 接入：每个工作线程预投递 32 个 `AcceptEx`（总数上限 1024），完成由接入 IOCP 回收；已连接的 RIO socket 按轮转分配给固定工作线程，工作线程用同一 operation 地址回执握手。
- TCP 数据：每个连接拥有一个 RIO RQ；每个工作线程独占一个 RIO CQ、一个 IOCP、一块预注册内存和一份索引最小堆。
- UDP 数据：预投递固定深度的 `RIOReceiveEx`，完成后用 `RIOSendEx` 回显，再恢复接收。
- CQ 唤醒：IOCP 只表示“RIO CQ 可读”；线程批量 `RIODequeueCompletion` 排空 CQ 后按需调用 `RIONotify`。通知是**惰性**的：只有在途请求存在时才登记注册，空闲工作线程不持有挂起的 `RIONotify`，因此释放前不需要取消或排空注册（`RIONotify` 在 CQ 非空时立即通知，投递与武装之间不会丢唤醒）。
- 生命周期：接入只在全部 TCP 工作线程完成 IOCP/CQ/arena/定时器初始化后开放；停止时先关闭 `AcceptEx` 接入并 join 接入线程，再向工作线程发布 admission-closed 屏障与 stop，全部 join 后才释放注册资源。UDP 停止先关闭 socket 请求取消，再继续排空 CQ，注册内存、请求上下文和 CQ 在 `outstanding == 0` 前不会释放。
- `RIONotify` 只有 `ERROR_SUCCESS` 被接受；`RIO_CORRUPT_CQ`、必需的通知失败和不可缺少的 IOCP 控制投递失败属于内部不变量损坏，进程以退出码 4 确定性终止，不重试、不轮询 CQ，也不切换后端。
- 每个工作线程的数据面等待由 RIO CQ 通知和最近空闲截止时间驱动；TCP 协调器以最长 10 ms 采样停止与失败状态（`/w` 到期同样在此判定），接入线程和 UDP 循环使用最长 100 ms 的有界 IOCP 等待。这些控制等待不处理替代数据路径。
- TCP 与 UDP 的单次 CQ 排空都在连续 64 个完成批次后把控制权交回主循环，并在排空内部检查停止标志与 `/w` 期限；饱和流量下停止不会无限期推迟（实测：满速 UDP 洪泛下 Ctrl+Break 约 1.07 s 退出、TCP 突发下约 0.99 s，均输出 `outstanding=0`/`active=0` 且 stderr 为空）。未取走的完成仍留在 CQ 并由下一次通知取回。

## 构建与运行

要求 Windows 10 或更新版本、Swift 6.4 Windows 工具链及配套 Windows SDK、PowerShell 7。无第三方 Swift 包，不依赖相邻客户端或服务端源码。工具链及运行库须在 PATH 中。

```powershell
swift build -c release --product swift-echo-server
$bin = swift build -c release --show-bin-path
& "$bin/swift-echo-server.exe" /p tcp /s 7000 /threads 8 /cq 65536 /memory 2147483648 /stats
& "$bin/swift-echo-server.exe" /p udp /s 7000 /k 4096 /cq 8192 /memory 1073741824 /stats
& "$bin/swift-echo-server.exe" /h
```

完整验证使用 `pwsh -NoProfile -File build_debug.ps1` 或 `build_release.ps1`：构建、Swift Testing、所有权编译正反例、源码策略、原生内存安全正反例、验证门回归、TCP/UDP 进程验收、扩展场景（含 Ctrl+Break 受控停止与宽字符参数），以及已经单独验收的 `swift-echo-client` 与 `cpp-echo-client` 对同一二进制的互操作（客户端逐字节校验回显，退出码 0 才表示没有损坏或丢失，并与服务端 `bytes` 对账）。所有子进程有超时，结束时清理。

当前 Swift 6.4 Windows 默认构建后端的 Release 测试运行器会遗漏测试 DLL，导致发现零个测试。验证脚本仅在单元测试阶段显式采用 `swift test -c release --build-system native`（Debug 同样采用 native），核心模块与测试均按对应配置编译；正式服务端构建仍使用默认后端。脚本拒绝零测试结果，具体证据见工具链文档。

```powershell
pwsh -NoProfile -File tests/ces_standalone_check.ps1 -Configuration release
```

该命令将包复制到独立目录，排除原构建缓存，再运行同一完整验证，证明构建与测试不依赖相邻项目。

## 参数与结果

| 参数 | 默认值 / 语义 |
|---|---|
| `/p tcp\|udp` | 必填；不接受位置参数 |
| `/s` | 端口 7；1..65535 |
| `/t` | TCP 空闲超时 300 秒；1..4294967295；仅 TCP |
| `/w` | 默认不设时限；指定后到期受控停止 |
| `/b` | 0（系统默认）；`SO_SNDBUF`/`SO_RCVBUF`，0..2147483647 |
| `/k` | UDP 并发深度 256；1..65536；仅 UDP |
| `/threads` | 0 表示 min(max(CPU,1),32)；1..64 |
| `/rio-buffer` | TCP 每槽 16384 字节；UDP 省略时取 65507，显式值不得小于 65507；512..1048576 |
| `/cq` | 每 CQ 容量 4096；64..1048576 |
| `/memory` | 注册内存上限 1073741824；≥1048576 |
| `/q` | 接受但不改变输出；服务端仅在 `/stats` 时输出 |
| `/stats` | 输出逐工作线程记录与 `final` 汇总 |
| `/h`、`/help` | 打印用法并退出 0；语法与范围错误仍返回退出码 1，不会被 `/h` 掩盖 |

开关接受 `/x`、`-x`、`--x` 与 `=值` 形式；开关名和 `tcp`/`udp` 值按 ASCII 大小写不敏感比较。未知开关、空值、给 flag 开关附加值、位置参数或越界数值都返回退出码 1。

退出码：0 成功（含受控停止）、1 参数/负载无效、2 网络准备失败（bind、RIO/IOCP/容量）、3 未使用、4 内部错误。

`/stats` 保留 TCP 的逐工作线程记录，并在所有工作线程加入、接入屏障关闭且 RIO 终态完成排空后输出 `final protocol=tcp ... active=0` 汇总。UDP 在通知状态解除且 `outstanding=0` 后输出 `final protocol=udp` 汇总。`bytes` 只累计成功 RIO 发送完成的字节，`MiB_per_sec` 使用至少 1 ms 的保护后运行时间；UDP 的 receive/completion 数还包含停止期间排空的终态完成，因此不把接收块数标为逻辑 echo 数。

TCP 的 CQ 容量至少按每连接两个完成槽计算；UDP 至少按深度的两倍配置。回环结果主要反映本机协议栈、调度与内存路径，不代表真实网络或目标 NIC 的上限。

## 实现与部署

核心位于 `Sources/CESServerCore`；`Sources/swift_echo_server` 只是入口。原生资源使用 `~Copyable` 所有者、`UniqueArray` 与 borrow/mutate 访问器，负载视图使用 Span/MutableSpan，完成结果使用 InlineArray；停止标志和失败标志使用 Synchronization.Atomic。每个 Windows 工作线程独占连接表、请求上下文表、CQ、IOCP、注册 arena 与索引堆；RIO 上下文在解引用前按分配范围、对齐和字段身份校验。停止先关闭 socket，再排空完成、完成通知握手、join，最后释放资源。全程保持 Swift 6 并发、所有权与严格内存安全检查。

运行目录须能找到 Swift 6.4 的 `swiftCore.dll`、`swiftWinSDK.dll`、`swiftSynchronization.dll`、`Foundation.dll`、`FoundationEssentials.dll` 及其传递依赖，同时具备 MSVC x64 运行库和 Windows UCRT。最直接的部署方式是安装匹配的 Swift 工具链并保留其运行库 PATH；单拷贝 exe 到没有运行库的机器不能运行。开发测试不需要额外服务。

[与 C++ 基线的详细对照](docs/comparison.md)（契约、结构、验证覆盖、性能与资源表格）、[工具链与验证证据](docs/toolchain-interop.md)、[行为差异](docs/behavior-differences.md)、[性能测量](docs/performance.md)。
