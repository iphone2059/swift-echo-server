# 共同规范静态审查与修订记录

日期：2026-10-14（Asia/Singapore）。范围：`docs/CPP_Rust_Zig_Swift_Refactoring_Spec_v2.0.md`。本记录区分已完成文档修订、只读环境观测与尚未完成的实现验收；未运行格式化、编译或测试，未提交仓库。

## 修订及依据

| 修订 | 依据 | 验收含义 |
| --- | --- | --- |
| 增加 Echo 适用条款与现行流程 | 根 `AGENTS.md` 的 main／no-worktree、源码阶段先完成、门禁与推送要求；2026-10-14 Swift 实施计划 | 历史 worktree 和提前编译步骤不能覆盖现行约定；保留既有改动，源码静态复审结束后统一门禁 |
| 明确当前二进制契约载体，登记旧文档冲突 | 八仓 `tools/verification/contract-version.txt` 均为 `echo-binary-contract-v1`；`zig-echo-client/docs/parity-contract.md`；`rust-echo-client/docs/status.md`；当前源代码 | 根 `docs/echo-contract.md` 的旧 FIFO／禁 WAITALL／每 echo 延迟／4096 桶条款不能把实现改回旧算法；没有同名 `echo-binary-contract-v1.md` |
| 填写 Client／Server 真实职责映射 | Rust Client 的九文件、Server 八文件；Zig 对等清单和 `root.zig`；Swift 实施计划所定 `Sources` 结构 | Swift 业务文件八／七；根 `Package.swift` 真实模块声明是唯一模块索引例外，无空文件或整体转发占位 |
| 保留 C++ 真实物理边界 | `cpp-echo-client/src` 四 cpp、`include` 三 h；Server 四 cpp、四 h | C++ Client 实为七文件，不能虚称九文件；成组职责／语言专用声明另登记，不擅自拆 C++ |
| 增加五层、依赖方向及四类数据契约 | `AGENTS.md` 跨语言约定；`zig-echo-client/src/internal.zig:718` Core、`:843` RioTransport；`zig-echo-client/src/engine.zig` Runtime；`zig-echo-server/src/internal.zig:1778` UDP Engine、`:1940` Runtime；Rust 对应模块 | Transport→Event→Runtime→Engine→Action→Runtime→Transport；Scheduler 不读原生状态；同事件序列比较 Action／状态／账本 |
| 区分取消、完成、提交回滚与代际排空 | `AGENTS.md`；`rust-echo-client/src/engine.rs:777` generation drain、`:1337` 发布判断；Zig generation_drained 路径；[Microsoft CancelIoEx](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelioex) | 已被 provider 接管的 outstanding 由 Completion 归还；立即拒绝提交单独回滚；GenerationDrained 不能提前发布 |
| 增加全 Join→集中检查→释放与内部 guard | `zig-echo-client/src/engine.zig:307`／`:309`；`zig-echo-server/src/server.zig:201`／`:203`；`rust-echo-server/src/internal.rs:3518`／`:3529`；C++ client/server coordinator 对应循环 | 部分启动失败也先 Join 全部；release／destroy／deinit 内部再次 guard，检查先于释放 |
| 增加 fail-fast 正向与释放顺序证据 | `AGENTS.md`；`zig-echo-server/tests/fault_process_tests.ps1` 的 worker_not_started、acceptor 栈上状态证明与 partial_worker_start | 仅期待失败退出码不足；必须证明合法输入可通过，提前释放无法制造同一具名失败信息 |
| 固定二进制与模式，完整保留失败轮次 | `AGENTS.md`；两个 Zig `build.ps1` 的 build-manifest／SHA-256／optimize_mode 写入 | Debug／ReleaseFast 共用路径，测量前核验实际二进制；抽象门禁通过后才正式性能基线 |
| 更新验证次序和工件／验收模板 | `AGENTS.md`；Swift 实施计划；规范原 E0、语义、安全与性能门禁 | 保留原严格要求，未放宽零回退、状态一致性、热路径或安全验收 |
| 补 Rust Windows 依赖专门规则 | `AGENTS.md`；两个 `Cargo.toml` 的官方 Git URL，无 rev；[Microsoft windows-rs](https://github.com/microsoft/windows-rs) | 跟踪默认分支、不提交锁文件；每轮仍记录实际解析 SHA，和编译器冻结区分 |

## 官方发布参考与本机身份

官方通道在 2026-10-14 查阅，未据网页推定本机安装版本：

- [LLVM 首页](https://llvm.org/) 显示 LLVM 23.1.3，发布日 2026-10-06；[Clang 特性状态](https://clang.llvm.org/cxx_status.html) 有 Clang 24 开发特性。原官方参考保留。
- [GCC 首页](https://gcc.gnu.org/) 显示 GCC 16.2，发布日 2026-08-07；开发 GCC 17.0。原官方参考保留。
- [Rust 官方 1.99.0 公告](https://blog.rust-lang.org/2026/10/01/Rust-1.99.0/) 发布日 2026-10-01。原稳定版参考保留。
- [Zig 下载页](https://ziglang.org/download/) 显示 0.17.0（2026-10-01），master `0.18.0-dev.246+05671ced9`（快照日期 2026-10-12）；原 master dev.146 更新为该已观察值，不承诺所有平台的即时最新版。
- [Swift Windows 页](https://www.swift.org/install/windows/) 显示 6.4.1 容器以及 main（2026-10-11）／release/6.4.x（2026-10-08）快照；[官方发布负责人公告](https://forums.swift.org/t/announcing-swift-6-4-1/90029) 在 2026-10-13 发布 Swift 6.4.1。6.4.0 主要特性说明保留。公告正文打开失败，搜索工具返回的官方公告内容确认版本与日期；未据此写入任何未核实特性。

本机只读命令结果：

```text
MSVC 默认工具集：14.51.36231
cl /Bv：19.51.36260（无输入源码，打印版本后 D8003；没有执行编译）
PATH clang --version：21.1.6
rustc -vV：1.101.0-nightly，e9bbadf6824e65b3583c2dda3a0926ec76df9143，2026-10-12
cargo -vV：1.101.0-nightly，29c5daa1afc262323364e039bb70c83372cc702c，2026-10-07
swift --version / swiftc --version：6.5-dev，LLVM a0a7653f4c0c1a0，Swift ac2207a7efaa55c
VS Code Zig 0.17.0 安装目录中的 zig version：0.17.0
旧 C:/bin/zig-x86_64-windows-0.17.0-dev.2375+d8aab4878/zig.exe：不存在
SDK 已安装目录：10.0.22621.0、10.0.26100.0
```

保留的 2026-10-13 C++ CMakeCache 明确选 MSVC `14.51.36231`，并非 PATH Swift Clang。Zig 当前 `build.ps1` 接受 `0.17*` 并可回退 VS Code 安装目录；本机 `lib/std/lang.zig` 兼容 Debug→debug、ReleaseFast→fast。故规范不把旧固定 dev.2375 README 或 master 命令描述等同当前冻结产物。实际产物身份仍由统一门禁后的构建证据确定。

## 静态验证与未完成项

- 已核对规范新增段落、表格分隔与现有核心条款；相对 Markdown 链接指向现有工作区文件。
- 新增 Swift 结构是本次验收目标，不声称旧十四／十五个生产 Swift 文件已完成收敛。
- 根 `docs/echo-contract.md` 的冲突仅在共同规范中登记，本次文档范围未直接重写该文件；旧算法不能作为本轮对齐目标。
- 既有 Zig 工具链 README／部分故障脚本仍存在历史描述差异；本轮没有修改 C++／Rust／Zig 源码或脚本。规范约束不构成这些仓库已通过新证据门禁的声明。
- 未开始正式性能测试，未声称 E0、吞吐零回退或全部语言抽象一致性已验收。

## Client 低依赖源码接续审查

协调器随后授权本 agent 负责 Client `contract.swift`／`types.swift`／`payload.swift`／`metrics.swift`，与 client_audit 分离文件归属；未编译、未测试、未格式化、未提交。

- `contract.swift` 对照 C++ `src/cec_contract.cpp`、Rust `src/contract.rs`、Zig `src/contract.zig`：显式 `/threads 0`、`/w 0`、`/report 0` 接受；`/rc` 覆盖 UInt32 完整范围；严格 UTF-16 保留 token 与末尾 literal 的诊断顺序；help 仍验证可决定的交叉、2*s*batch 内存与 2*shard CQ 规则。Usage 的行序和文本只替换可执行文件名。
- `types.swift` 汇合常量、Operation／Phase、Failure 分类／域／原始码，并提供中立的已初始化有界存储视图。该视图不拥有资源，unsafe 构造明确要求稳定地址、初始化、访问归属与 owner 存活；Native 导出也须保持 unsafe 边界，不能假称有静态生命周期保证。
- `payload.swift` 保留确定性 binary／printable／UTF-8 字节；恢复不可变 CECPatternStorage 兼容 API，新增纯字节计数与无分配填充入口以支持可失败的原生启动存储。UniqueArray 与 class 原有启动构造的 OOM 不能被 `.allocationFailure` enum 名称当作已处理；已交协调器／client_audit 处置生产存储。
- `metrics.swift` 补 worker-local attempted(claimed)／cancelled／原生收发字节／连接与重连／active／fatal／样本总数与总和；合并维持 wrapping 计数，pending 为 claimed 减 terminal 的饱和差；mean 用真实样本总和而非桶均值；最高桶报告 `1 << 63`，不是 UInt64.max。

完整 stdout 字段与数值三方证据：C++ `src/cec_engine.cpp:955` 的 percentile 和 `:983` 起 `cec_engine_print_metrics`；Rust `src/metrics.rs:198` 起 `StatisticsLine::fmt`；Zig `src/metrics.zig:143` 起 `Statistics.writeLine`。三方均为 `sessions active attempted pending echoed corrupted lost cancelled sent_bytes received_bytes bytes connections reconnects network_errors ... p50 p99 p999 mean_us max_us latency_sample=batch`，生产 64 桶，max 为最后样本所在桶下界。

旧 Swift CECMetricsTests 的 hasPrefix（sessions 后紧接 echoed）及缺 mean 的连续子串与三方冲突，已报协调器。用户随后明确授权定点同步旧断言，client_audit 负责；本 agent 新增独立 `CECBinaryContractAlignmentTests.swift` 的完整 literal 输出、显式零、UInt32 reconnect、UTF-16 诊断、内存/CQ与最高桶回归。新增测试未运行，旧断言修改不由本 agent 执行，未引入第二套 legacy 生产输出。

Failure 的静态复审补充：Rust `types.rs` 的 classification/domain/stage/code 与 Zig `types.zig:35` 的 domain（含 capacity）/category（initialization、connection、provider、invariant）/retryable 存在不同表达维度。Swift 共享 CECFailure 保留全部字段，新增负载保存回归；不能把默认 initialization/false 当作所有 native/runtime 路径的实际分类。已与 client_audit 协调 NativeError 转换与按对应阶段赋值。
