# C++ Rust Zig Swift 跨语言对等重构规约

版本：v2.0（强一一对应、极端性能与安全约束版）

修订日期：2026 年 10 月 14 日（工作区约定、实际源码映射与工具链通道复核）

本规约覆盖 C++、Rust、Zig、Swift 的全部 12 个有向迁移组合。迁移必须保持领域抽象、源码职责、组件关系和可观察行为，同时满足预先冻结的性能与安全要求。允许使用目标编译器已经实现的最新语言特性，并逐项验证其可用性与生成代码。

核心原则：共同契约先行，所有权与资源生命周期从首次移植就正确设计；极端性能通过热路径成本和实测门禁验收，安全通过类型约束、有效性前提、边界校验及验证证据保障。无法同时满足约束的迁移方向不得声明完成。

## 1 适用范围与规范用语

“必须”表示验收要求；“禁止”表示在当前约束下不可执行；“应”表示通常采用，偏离须说明依据；“可”表示条件满足后允许。

项目必须选定替换模式或并行模式。替换模式允许目标实现逐步接管并最终淘汰来源实现；并行模式维护一份共同契约及多种持续有效的实现，不以删除来源代码为目标。参考实现由项目指定，不固定为 C++；参考实现与共同契约冲突时，先处置冲突。

| 语言对 | 方向一 | 方向二 |
| --- | --- | --- |
| C++ 与 Rust | C++ 到 Rust | Rust 到 C++ |
| C++ 与 Zig | C++ 到 Zig | Zig 到 C++ |
| C++ 与 Swift | C++ 到 Swift | Swift 到 C++ |
| Rust 与 Zig | Rust 到 Zig | Zig 到 Rust |
| Rust 与 Swift | Rust 到 Swift | Swift 到 Rust |
| Zig 与 Swift | Zig 到 Swift | Swift 到 Zig |

每个箭头都是独立的验收对象。正向通过不代表反向通过；经第三种语言转译也不能替代对共同契约的重新验证。错误负载、所有权保证和运行时成本可能在中间步骤丢失。

语言规约适用于系统编程项目。本文的操作系统实例和 I/O 门禁以 Windows 原生 IOCP、Winsock RIO、Windows I/O Ring 为准；迁移不得顺带替换操作系统后端。Windows 版本、SDK、CPU 架构和 API 能力必须冻结。

### Echo 工作区的现行适用约束

`C:\Users\Administrator\echo-project` 下的八个 Echo 仓库采用并行模式，各自保持独立源码、构建、测试、依赖和可执行文件。当前数据面为 Winsock RIO，完成与控制面为 IOCP，TCP 使用 ConnectEx／AcceptEx；本文列出的 I/O Ring 是其他项目可采用的实例，不授权 Echo 更换后端。

本工作区的操作流程以根目录 [AGENTS.md](../AGENTS.md) 为硬约束：每个仓库只保留 `main`，直接在现有仓库修改，不创建分支或 worktree；开始修改前及推送完成后核对 `main...origin/main` 为 `0 0`。保留用户已有改动。源码、语义、架构对齐与静态复审全部完成后，统一执行 `format.ps1` → `build_release.ps1` → `build_debug.ps1`；Release、Debug 均运行 CTest 与 reset storm，全部通过才提交并推送 `main`，再核对远端 SHA 与本地一致。本约定替代历史计划中的 worktree 流程和提前编译测试步骤。需要保留的实验内容先归档到 `.superpowers` 下的压缩包或 bundle，再清理本次遗留内容；不得覆盖其他正在进行的工作。

当前共同二进制契约版本标记为 `echo-binary-contract-v1`，实际入口是八仓的 `tools/verification/contract-version.txt` 与同目录验收入口，结合冻结源码、共同测试及 [Zig Client 对等契约](../zig-echo-client/docs/parity-contract.md) 核对；该 ID 不表示存在同名 Markdown 文件。根目录 [echo-contract.md](echo-contract.md) 中 2026-10-03 的 FIFO 流装配、禁止 `RIO_MSG_WAITALL`、每 echo 延迟与 4096 桶描述未随当前实现同步，属于待更新的冲突记录，不能据其把当前 batch、WAITALL 与 64 桶生产统计改回旧算法。发现其他契约冲突须记录并共同处置，不能以迁移为名自行选择较宽松的验收要求。

## 2 最新工具链与特性使用规则

采用当前可获取且实现所需最新特性的编译器。开发快照可以作为项目基线，但必须固定到具体提交或可校验的安装包；不得让 CI 每次自动追随未冻结的 latest、master 或 nightly。

下表记录 2026 年 10 月 14 日查阅官方页面得到的发布参考与开发通道。页面更新日期、发布日期和查阅日期分别记录；开发通道所显示快照不保证是所有平台最新可用产物。它们不等于本机已安装或项目已冻结的基线，正式项目清单必须另填实际工具链、标准库、链接器、SDK 与验证结果。发布版和开发版是不同配置，不能混用其性能或安全结论。[1]–[8][33]

| 语言 | 官方发布版参考（本次查阅） | 官方开发通道与验收要求 |
| --- | --- | --- |
| C++ | Clang／LLVM 23.1.3；GCC 16.2 | 可选择 Clang 24 开发分支或 GCC 17 开发快照；Windows 上按实际 ABI、标准库和特性探针选择工具链 |
| Rust | Rust 1.99.0 | 所需特性未稳定时可使用带日期的 nightly；记录 rustc 提交、edition、目标三元组和 Cargo 配置 |
| Zig | Zig 0.17.0（2026-10-01 发布） | 下载页显示 master 为 `0.18.0-dev.246+05671ced9`（页面快照日期 2026-10-12）；固定完整版本、目标、后端与优化模式 |
| Swift | Swift 6.4.1（2026-10-13 发布公告；6.4.0 为主要特性发布） | Windows 页提供 main（显示 2026-10-11）与 release/6.4.x（显示 2026-10-08）快照；选定实际安装包，记录语言模式、提交和运行时版本 |

2026-10-14 本机只读查询结果如下。这是环境观测，不能替代完成门禁后冻结的构建清单，也不自动授权升级仓库基线。

| 工具链 | 本机观测 | 与冻结构建的关系 |
| --- | --- | --- |
| C++ | Visual Studio 18 Enterprise 默认 MSVC 工具集 `14.51.36231`，`cl /Bv` 为 `19.51.36260`；PATH 中 Swift 附带 Clang 为 `21.1.6` | 2026-10-13 保存的 C++ CMakeCache 选择上述 MSVC；不能把 PATH Clang 或官方 LLVM 23.1.3 写成本项目实际编译器 |
| Rust | `rustc 1.101.0-nightly`，提交 `e9bbadf6824e65b3583c2dda3a0926ec76df9143`（2026-10-12），目标 `x86_64-pc-windows-msvc`；Cargo `1.101.0-nightly`（`29c5daa1a`） | 记录每次实际构建版本；Rust 1.99.0 是官方稳定版参考，不是当前安装版本 |
| Zig | VS Code 安装目录中的 `zig version` 为 `0.17.0`；历史 `C:\bin\zig-x86_64-windows-0.17.0-dev.2375+d8aab4878` 不存在 | 当前脚本接受 `0.17*` 且可选择该安装目录；旧 README 的固定 dev.2375 描述不能作为新产物身份，必须保存实际路径、版本与 SHA-256 |
| Swift | `Swift version 6.5-dev`，LLVM `a0a7653f4c0c1a0`，Swift `ac2207a7efaa55c`，目标 `x86_64-unknown-windows-msvc` | Swift 6.4 发布参考及 `swift-tools-version`／语言模式不能代替实际 6.5-dev 编译器身份与特性探针 |

本机已安装 Windows SDK 目录包含 `10.0.22621.0` 与 `10.0.26100.0`；实际构建选择、部署系统和 API 能力须在构建证据中单独冻结，不能仅据安装目录推定。

Echo 的 Rust Windows 依赖遵守工作区专门约定：追踪官方 `microsoft/windows-rs` 默认分支，不指定固定 `rev`，不保留或提交 `Cargo.lock`；构建前清理锁文件并更新 Git 依赖，验证后再次清理锁文件。每轮验证必须在证据中记录实际解析到的依赖提交，编译器冻结与依赖跟踪是两个独立规则，不能用追踪默认分支掩盖验证产物身份。[34]

“最新编译器”不构成“所有语言及库特性都完整实现”的证明。C++ 编译器前端、标准库、ABI 和目标平台分别验收；某一编译器在某项特性上实现较新，不能推导其他特性也受支持。[2]

每个引入的特性必须登记名称或提案、最低已验证版本、启用选项、目标平台、编译与链接探针、运行结果，以及生成代码或成本证据。特性探针必须使用项目实际工具链，不以网页状态表代替构建结果。

允许概念约束、编译期计算、反射或宏、最新所有权特性、借用视图、SIMD、固定容量与独占容器等表达。使用条件是保持原职责、调用能力、安全前提和成本预算。没有义务为了“用最新特性”替换已经满足契约的实现。

## 3 必须保持的对应关系

| 维度 | 冻结内容 | 主要证据 |
| --- | --- | --- |
| 语义 | 输入输出、错误、边界、状态转换、副作用和资源回收 | 共同契约与差分记录 |
| 抽象 | 实体身份、职责、接口能力、分派、所有权及借用关系 | 双向实体和接口映射 |
| 文件 | 逐物理文件对应、目录归属及文件职责 | 双向文件清单 |
| 架构 | 组件边界、依赖方向、状态归属、线程和队列拓扑 | 组件与依赖审查 |
| 性能 | 复杂度、分配、复制、引用计数、同步、系统调用与实测预算 | 成本记录与基准结果 |
| 安全 | 有效值、边界、初始化、生命周期、别名及并发不变量 | 类型检查和安全论证 |

每个冻结的逻辑实体必须有唯一对等实体。一个实体可以由目标语言的类型、方法、协议或编译期生成项共同表达；必须列出这些关联项，不能借此合并原抽象、转移业务职责或改变状态归属。

公共接口保持谁拥有、谁借用、是否可复制、何时转移、失败后归谁、谁释放、地址何时有效等契约。函数签名允许语言适配，但调用方获得的能力与承担的前提必须等价。

### 逐文件对应

默认采用 F1：每个纳入范围的物理源码文件有唯一目标文件，并保留其职责。禁止用空文件、整体转发或集中业务实现满足文件数量。目录保持可对照，语言模块声明不得形成新业务层次。

| 来源职责 | C++ | Rust | Zig | Swift |
| --- | --- | --- | --- | --- |
| 入口装配 | main.cpp | main.rs | main.zig | main.swift |
| 引擎接口 | engine.h | engine_api.rs | engine_api.zig | engine_api.swift |
| 引擎实现 | engine.cpp | engine.rs | engine.zig | engine.swift |
| 配置接口 | config.h | config_api.rs | config_api.zig | config_api.swift |
| 配置实现 | config.cpp | config.rs | config.zig | config.swift |

此表是有相应职责时的映射示例，不要求把原来合在一个文件中的接口和实现强行拆开。反向迁移到 C++ 时，可在对等源文件中定义类型及实现；确需新增头文件时，必须列为语言专用声明例外，逐项说明声明来源，不新增业务职责。

构建脚本、模块索引、生成声明及必要 ABI 适配文件必须进入例外清单。Swift 在同一模块中通过 extension 组织方法、Rust 将 impl 放入对应实现模块、Zig 组织 import，均须核对可见性、依赖和清理代码实际归属；类型定义与析构实现必须服从目标语言要求。

F2 允许把预先声明的逻辑文件组作为映射单元，例如一组 .h／.cpp 对应一个 .rs、.zig 或 .swift。F2 须明确批准，采用后不能声称物理文件严格一一对应。若 F1 与语言有效性要求无法同时成立，应记录冲突并调整对应规则，不能制造无效实现。

### Echo 的具体文件映射

Rust 与 Zig 保持 Client 9、Server 8 个生产源文件，包括真实模块入口 `lib.rs`／`root.zig`。Swift 对应 Client 8、Server 7 个生产源文件；SwiftPM 在根目录 `Package.swift` 中实际声明 target／module，这是唯一模块索引语言例外，不移动到 `Sources`，不创建空 `lib.swift`／`root.swift` 或整体转发文件凑数量。所有业务职责仍逐文件对应；新增 `WorkerCore`／`RioTransport`／`WorkerRuntime`／`UdpEngine` 等逻辑类型放入既有职责文件，禁止为抽象增加文件、热路径动态分派、每次调用的堆分配或无必要的参数搬运。

| 共同职责 | Rust Client `src` | Zig Client `src` | Swift Client |
| --- | --- | --- | --- |
| 应用入口 | `main.rs` | `main.zig` | `Sources/main.swift` |
| 模块入口 | `lib.rs` | `root.zig` | 根 `Package.swift` 的真实模块声明（语言例外） |
| 选项、共同值与算术 | `types.rs` | `types.zig` | `Sources/types.swift` |
| 参数与容量契约 | `contract.rs` | `contract.zig` | `Sources/contract.swift` |
| 字节负载 | `payload.rs` | `payload.zig` | `Sources/payload.swift` |
| 统计账本与生产延迟 | `metrics.rs` | `metrics.zig` | `Sources/metrics.swift` |
| 原生 API 与资源所有者 | `native.rs` | `native.zig` | `Sources/native.swift` |
| Session、Scheduler、Worker Core、Timer | `internal.rs` | `internal.zig` | `Sources/internal.swift` |
| Transport、Worker Runtime、运行协调 | `engine.rs` | `engine.zig` | `Sources/engine.swift` |

| 共同职责 | Rust Server `src` | Zig Server `src` | Swift Server |
| --- | --- | --- | --- |
| 应用入口 | `main.rs` | `main.zig` | `Sources/main.swift` |
| 模块入口 | `lib.rs` | `root.zig` | 根 `Package.swift` 的真实模块声明（语言例外） |
| 选项、共同值与统计 | `types.rs` | `types.zig` | `Sources/types.swift` |
| 参数与容量契约 | `contract.rs` | `contract.zig` | `Sources/contract.swift` |
| 原生 API 与资源所有者 | `native.rs` | `native.zig` | `Sources/native.swift` |
| 纯 TCP Engine | `engine.rs` | `engine.zig` | `Sources/engine.swift` |
| Acceptor、Connection、UDP、Worker、Timer 与对应 Runtime | `internal.rs` | `internal.zig` | `Sources/internal.swift` |
| 协议装配与停止协调 | `server.rs` | `server.zig` | `Sources/server.swift` |

以上为本次 Swift 对齐的验收目标，文件清单本身不证明当前实现已符合。C++ 当前生产 `src`／`include` 物理文件为 Client 7、Server 8，保留原有头文件／实现边界；其 `cec_*`／`ces_*` 内部职责须在实体及成组文件清单中对应，不能虚称 C++ Client 也有 9 个物理文件，不能据 Rust／Zig 数量擅自拆分 C++。C++ 编译器约束和 RIO 布局声明等语言专用项进入例外清单。

## 4 共同抽象与数据表达

下表列出候选表达；同一行不构成自动等价或 ABI 兼容承诺。

| 共同职责 | C++ 候选 | Rust 候选 | Zig 候选 | Swift 候选 |
| --- | --- | --- | --- | --- |
| 值与状态实体 | class／struct | struct 与 impl | struct 与函数 | struct 与方法 |
| 静态接口 | template 与 concept | 泛型与 trait bound | comptime 类型及约束 | 泛型与 protocol 约束 |
| 独占资源 | 禁止复制的 RAII 包装 | 非 Copy 所有者与 Drop | 显式所有者及释放协议 | ~Copyable 包装与 deinit |
| 单个堆值独占 | unique_ptr 或专用包装 | Box 或专用包装 | 分配器与显式拥有者 | UniqueBox 或专用包装 |
| 有界借用视图 | span 或受约束视图 | slice 与引用 | slice 与访问协议 | Span／MutableSpan 与生命周期约束 |
| 可报告失败 | expected 或带标签结果 | Result | error union 或带负载 union | typed throws 或结果类型 |
| 可缺失值 | optional | Option | optional | Optional |
| 编译期专用实现 | constexpr／consteval／模板 | const／泛型／宏 | comptime | 已实现的泛型、宏或生成项 |

只有基线原本需要运行时开放多态时，才可保持相应的虚接口、trait 对象、函数表或 protocol existential。原实现采用静态分派时，不得为了接口形状相似而新增类型擦除。封闭枚举替换开放多态须先确认扩展能力属于可改变范围。

C++ 实现继承、Rust trait、Zig 编译期约束与 Swift protocol 并非同一种语言机制。必须分别核对替代关系、代码复用、数据布局和调用能力；组合或委托可以保持逻辑身份，但不能悄悄改变组件边界。

### Echo 逻辑分层与事件契约

| 层 | 共同职责 |
| --- | --- |
| Application／Coordinator | 入口、参数、Worker 创建、停止、Join、最终统计 |
| Worker Runtime | 事件循环、完成处理调度、Action 执行 |
| Pure Engine | Session／Connection／UDP／Acceptor 状态机、Scheduler、Timer、Statistics |
| Transport | RIO 请求、ConnectEx／AcceptEx、Completion 归一化与原生代际核算 |
| Native／Resource Ownership | Win32、Winsock、IOCP、RIO、Socket、CQ、RQ、OVERLAPPED、Arena |

各语言的执行链必须一致：`Transport → Event → Worker Runtime → Pure Engine → Action → Worker Runtime → Transport`。Pure Engine 与 Transport 不得相互依赖，由 Worker Runtime 协调；Scheduler 不读取原生 Slot、RQ、OVERLAPPED 或 provider outstanding，Transport 判定原生 drain 后通过事件报告。Pure Engine 可维护自己的逻辑操作账本，但不能把它当作原生资源已经可释放的证明。

| 统一数据 | 契约 |
| --- | --- |
| `Completion` | 原生完成记录的规范化表示，携带操作、上下文、代际、状态与字节等核算信息 |
| `Event` | 已完成原生所有权核算后交给 Pure Engine 的事件 |
| `Action` | Pure Engine 的业务决策，由 Worker Runtime 执行 |
| `Lifecycle` | 可释放性与退出状态，语言机制不同但判定条件一致 |

类型名称与语言表达可不同；状态集合、转移条件、事件优先级、Action 顺序、操作归属计数、取消语义、释放顺序和 stdout／统计账本／错误分类／退出码必须一致。逐函数比较前置条件、后置条件与事件顺序；纯 Engine 必须可独立测试，Transport 可由测试实现替换。相同输入事件序列必须产生相同 Action 序列、状态快照与统计账本；端到端跑通不能替代抽象一致性门禁。

## 5 所有权与资源生命周期

每种资源必须记录创建者、唯一或共享拥有者、借用者、线程归属、地址要求、转移点、完成条件和释放动作。资源包括堆内存、句柄、注册缓冲区、请求槽、回调上下文、队列和外部运行时对象。

| 生命周期事件 | 必须满足的条件 |
| --- | --- |
| 创建与注册 | 分配、初始化、注册失败时按已完成步骤回退 |
| 借用与提交 | 长度、对齐、可变访问及存活期限均成立 |
| 转移 | 前拥有者停止释放和访问，失败转移语义明确 |
| 完成与排空 | 完成次数、在途数量和通知消费条件符合 API 契约 |
| 取消与关闭 | 请求取消、停止提交、等待完成分别处理 |
| 回收与复用 | 无外部访问、无在途操作、无有效旧借用或旧代请求 |

非复制类型、固定容量容器、堆分配、地址固定与资源存活是不同保证。禁止把 Rust 的 move、C++ 的 move、Swift 的 consuming 或 Zig 的赋值，当作异步请求可以立即回收的依据。

Rust Pin 对地址敏感对象施加约束，不能代替外部操作完成前的资源持有；可重分配容器也不会因包装对象被固定就自动固定内部缓冲区。[16]

Swift UniqueBox 的堆内值具有稳定地址，但其公开接口、借用期限和资源存活仍需分别核对；UniqueArray 可增长，RigidArray 仍是堆分配容器，均不能被理解为“创建时无分配”。[9][10]

来源要求可恢复 OOM、定制分配器或特殊释放动作时，普通 Box、unique_ptr、UniqueBox 或独占数组都不能仅凭名称判定等价。必须核对具体构造和分配 API 的失败能力；不满足时提供保持相同契约的专用包装。

存在释放依赖时，必须显式核对顺序。C++ 成员按构造逆序销毁，Rust struct 字段按声明顺序销毁；Zig 依赖显式释放与作用域清理，Swift 的 deinit／引用生命周期也不能按 C++ 字段顺序推断。[18][19]

关闭失败、重复关闭、提前释放及部分构造失败必须有定义行为。依赖某个时刻释放句柄时，应由明确的 close／drain 协议规定，自动析构仅执行符合状态的兜底清理。

### Echo 取消、Join 与释放边界

**取消 Socket 不等于完成 I/O。** 关闭 socket 只发起取消，不归还 provider 仍持有的请求；已成功提交操作的 outstanding 只能在收到并核算 Completion 时递减。提交 API 立即拒绝且 provider 从未接管的请求按明确回滚规则处理，不能伪造完成事件抵消已接管请求。只有全部相关 Completion 均已收到并核算，Transport 才能发布 `GenerationDrained`；旧代际 context、RQ、注册缓冲区和 OVERLAPPED 在此之前保持有效，不复用、不覆盖、不提前释放。

协调器必须先停止并 Join 所有已启动 Worker，再集中检查全部相关释放不变量，最后统一释放；部分启动失败同样适用，已初始化未启动的资源单独纳入回滚范围。TCP Server 先关闭 admission 并 Join Acceptor，向 Worker 发布 admission-closed 和 stop，Join 全部 Worker 后再集中检查 Acceptor、Worker 与交接所有权。不得在 Join 第一个 Worker 后立即检查并释放它，而让其他线程仍在运行。

Windows 仍持有 OVERLAPPED／RIO 资源时，不变量破坏必须在释放边界之前 fail-fast。检查必须位于释放函数内部，集中检查不能代替每个 release／destroy／deinit 的内部防线；任何合法调用方都不能绕过。原生资源、通知绑定和宿主数组的实际释放次序须逐项映射，禁止先释放再用失效对象检查。每个 fail-fast 断言必须有合法状态的正向对照；释放顺序修复还须有能区分先检查与先释放的证据，例如使用栈上状态使错误释放无法产生预期的干净、具名边界信息。只核对 exit code 不足以证明边界顺序。

## 6 错误 数值与字节语义

共同错误模型至少包含错误域、原始码、类别、可重试性、已经发生的副作用、对象后续可用性和诊断字段。业务失败、缺失值、程序不变量破坏、进程终止与内存耗尽分别定义。

语言错误形式可以不同，但不能丢失负载。Zig error set 的错误标签不能直接承载任意 Result 错误对象或 Swift 关联负载；需要信息时使用显式结构或带标签结果，并保持接口职责。[6]

同一层的错误控制流必须对等：不能一边返回失败、另一边仅悄悄设置全局状态，除非 Worker Runtime 明确保证相同的后续 Action、停止传播与终止行为。可恢复业务失败与原生所有权不变量失败分别处理；后者不能转为释放后的普通错误返回。

输入验证失败必须转为约定的失败结果。panic、trap、unreachable、强制解包及 C++ 断言不替代可恢复业务错误。禁用 C++ 异常时，构造失败、分配失败与容器操作须有可落实的策略；Swift throws 不应仅因名称与 C++ throw 相似就被当作同一展开机制。

整数必须确定宽度、符号、截断、移位和溢出策略，区分 checked、wrapping、saturating 与拒绝输入。禁止依赖 C++ 有符号溢出，或依赖不同优化配置的默认溢出行为。Rust 发布构建的溢出检查设置必须显式记录。[20]

浮点必须冻结舍入、NaN、无穷、负零、FMA 和误差判定。启用 fast-math 或改用不同 SIMD 实现前，必须证明满足原契约；确定的协议字节不能以近似误差豁免。

原始字节、UTF-8、UTF-16 与用户可见字符分别建模。Swift String 的字符语义不能机械对应字节计数；不能把任意二进制负载转为文本再转回。容器替换须核对顺序、哈希、扩容、地址、初始化及复制语义。

## 7 极端性能配置与热路径成本

项目默认采用 E0 极端性能配置。实施前必须列出其适用热路径、最大并发、负载范围、必要复制、初始化阶段及错误路径。连接建立、扩容、取消和关闭是否属于热路径必须声明，不能通过缩小统计范围隐藏主要成本。

| 成本项 | E0 默认要求 | 证据 |
| --- | --- | --- |
| 稳态应用堆分配 | 每个请求与完成处理为 0 次；预分配在声明的准备阶段完成 | 分配追踪与调用栈 |
| 额外负载复制 | 0 次；必要复制单独列明字节数与原因 | 复制计数与生成代码 |
| 每请求引用计数 | 0 次 retain／release 或 RC／ARC 更新 | IR、汇编与剖析 |
| 隐式扩容与写时复制 | 热路径不触发；容量耗尽走既定背压或失败分支 | 容量与故障测试 |
| 分派 | 原本静态的路径保持静态，无新增类型擦除或间接调用 | 调用图与反汇编 |
| 任务与协程对象 | 无新增每请求分配、调度跳转或执行器切换 | 运行时事件与分配记录 |
| 同步与等待 | 不新增全局争用、锁、阻塞等待或未经预算的自旋 | 同步协议与 ETW |
| 系统调用与批处理 | 单位有效工作调用次数不增加，保持批量与完成消费规则 | 系统调用和批量记录 |
| 复杂度与缓存 | 不提高约定复杂度，不引入无界链、重试或扫描 | 审查与硬件计数器 |
| 检查成本 | 保留必需安全检查；允许证明后由编译器消除重复检查 | 校验前提与生成代码 |

应用分配统计须覆盖标准库、语言运行时、闭包、桥接及容器触发的分配。操作系统或驱动内部成本单列，不能宣称整机“零分配”。固定容量、预留容量和对象池都须验证真实的最坏分支。

如果基线在声明热路径中已有每请求分配、引用计数或不符合 E0 的同步成本，应先由共同契约管理必要优化；仍需保留时，必须列明项目例外及预算。存在例外的实现不能声称无例外通过 E0。

强一一对应约束下，不能仅在一个目标实现中合并层次、增加批处理队列或改变线程模型来达到 E0。架构优化须形成共同决策，更新对应约束并同步适用实现。

“零成本抽象”必须针对实际实例化和发布产物给出证据。泛型、trait、protocol、comptime、迭代器、借用访问器及宏的名称不构成零分配、零复制或完全内联的保证。

## 8 性能实测门禁

E0 的名义比较预算为不回退，同时满足项目的绝对吞吐、尾延迟、内存和容量目标。未填写绝对目标、测试范围和判定规则时，不能出具极端性能验收结论。

| 指标 | 必须报告 | 判定要求 |
| --- | --- | --- |
| 有效吞吐 | 有效请求／秒或有效字节／秒 | 相同负载及 SLA 下不回退 |
| 延迟 | p50、p95、p99、p99.9 及超时比例 | 各冻结分位和超时目标分别通过 |
| CPU 成本 | 用户态及内核态时间，单位有效工作成本 | 不能靠多用核心掩盖回退 |
| 内存 | 峰值、稳态、每连接及每在途请求成本 | 满足容量上限与成本预算 |
| 系统交互 | 系统调用、批量大小、上下文切换及线程数量 | 保持冻结的模型与预算 |
| 稳定性 | 长时运行、过载、取消、关停及恢复 | 无泄漏、无无界增长，完成与回收一致 |

固定硬件、核心数、CPU 频率策略、NUMA、亲和性、Windows／SDK、驱动、网络设备、MTU、负载程序及构建配置。来源和目标均使用各自已批准的优化发布配置；允许 LTO／WMO／PGO，但必须登记，PGO 训练负载不能替代独立验收负载。

测量前必须冻结源码提交、实际编译器与依赖身份、目标、优化模式、完整构建参数和每个可执行文件的 SHA-256，并校验将启动的二进制。Echo Zig 的 Debug 与 ReleaseFast 共用 `zig-out\bin`，必须按该目录 `build-manifest.json` 核对 `optimize_mode` 与 `binaries` 散列；仅凭路径或最后一次日志不能辨别模式，也不能混用两种模式排名。其他语言同样保存实际产物身份；没有完整来源证据的旧数据不能升级为正式基线。

失败轮次原样保留为失败记录；超时、崩溃、校验失败与无法完成的 drain 不删样、不重分类为有效测量。补测须按事前冻结的规则开展并保留所有轮次，禁止补跑到得到满意结果为止。正式性能基线只能在抽象一致性、资源所有权与共同契约门禁全部通过后开始。

采用交错的配对测量，例如来源与目标交替运行，防止温度、后台活动和网络状态造成顺序偏差。建议至少 5 组独立配对重复；次数、时长和样本量以能判定预定门禁为准，不能用固定次数替代精度检查。

对“越小越好”指标，回退量定义为目标值／参考值 - 1；对吞吐等“越大越好”指标，定义为参考值／目标值 - 1。报告原始数据、配对估计和预先选定的置信区间。

默认正回退预算为 0。采用单侧置信区间时，其回退量上界须不大于 0 才能证明通过该门禁；结论不确定则补测或改进实现。项目若批准正的等价容差，必须公开数值并标为容差验收，不能再声称严格零回退。

尾延迟不能仅看平均值。p99.9 应有足够的尾部事件；例如百万级样本可提供约千次超过该分位的观测，但相关性和测量方法仍须核对。闭环负载要识别因阻塞而漏发请求的测量偏差，使用预定的到达与计时规则。

网卡、磁盘或对端已饱和时，吞吐相同不能证明语言成本相同；仍比较 CPU、内核时间、内存及尾延迟，并设置能暴露实现成本的独立负载。至少覆盖小／大报文、低／高并发、接近饱和及过载分支。

## 9 安全硬约束

“安全通过”要求下列适用不变量有明确维护者与证据，不以测试全部通过推断不存在任何缺陷。

| 安全项 | 强制要求 |
| --- | --- |
| 边界与算术 | 验证长度、容量、偏移、计数、溢出和外部数据范围 |
| 初始化与类型 | 读取已初始化且符合目标类型有效值要求的数据 |
| 生命周期 | 禁止悬垂、提前回收、重复释放和失效回调 |
| 别名与可变访问 | 不产生冲突独占访问，不以转换伪造可变借用 |
| 并发 | 无数据竞争，发布、消费和回收的同步关系完整 |
| 资源与过载 | 请求、内存、队列、重试和日志增长均有上界 |
| 外部边界 | 调用约定、布局、分配器和展开策略一致 |
| 故障处置 | 部分失败、取消、关闭及异常输入不破坏状态 |

来源实现的未定义行为不能作为必须复制的契约。源代码中的合法输入范围与使用前提先冻结；发现缺陷时，记录并同步处置，不通过“忠实移植”延续无效内存访问。

Rust unsafe、Swift unsafe／Unmanaged、C++ 原始指针及 Zig 指针转换都必须登记安全前提。语法上没有 unsafe 关键字，不代表操作没有人工维护的安全义务。Rust 安全接口封装还必须保证合法安全调用无法触发内部未定义行为。[15]

需要保留来源的编译期保证时，目标必须有相应类型约束、可执行的静态检查或其他获准证明。把 Rust 的借用检查转换为 C++／Zig 的约定与测试，只能提供不同形式的证据；不得声称仍由同等编译期机制保障。缺少项目要求的保证时，该方向不验收。

默认禁止全局关闭边界、溢出或独占访问检查来换取成绩。移除局部检查须说明输入校验与不变量，证明状态在整个使用期间保持，并保留故障验证。C++ assume、Rust unchecked、Zig unreachable 与 Swift 不受检访问都只能表达已成立的前提。

无锁代码必须核对内存序、ABA、代号回绕、发布后可见性及回收协议。引用计数不自动使对象内部线程安全；线程安全类型也不能代替操作系统外部访问的生命周期管理。

密码学、认证或敏感数据处理若在范围内，必须保留其侧信道与机密性要求，采用已评审原语；不得为迁移自行替换密码算法。日志与故障注入不得泄露受保护内容。

## 10 四种语言的实施配置

### C++ 配置

优先使用实际工具链支持的概念约束、constexpr／consteval、span、expected、固定容量容器及 RAII。按项目冻结的约束禁止新增异常展开、RTTI、虚函数、std::function、隐式堆分配或共享所有权。

span 提供视图及长度表达，仍须保证来源存活、访问合法和并发条件。采用已实现的生命周期、Safe Buffers、线程安全分析和库加固时，记录其覆盖范围；不能把特定诊断当作通用借用检查器。[21][22]

资源类型明确复制与移动能力，所有转移保证单次释放；析构不能在仍有外部在途访问时回收。按目标可用性运行 ASan、UBSan、静态分析及模糊测试；生产发布仍保留必要有效性前提。

### Rust 配置

优先用独占所有权、引用、slice、Result、Option、泛型与 trait bound 表达共同契约。Box、Vec、Arc、Rc、dyn Trait、clone 和 async 的采用均须通过成本审查，不能作为借用冲突的通用补丁。

unsafe 限于必要边界，记录初始化、布局、别名、线程和回收前提。人工 Send／Sync、裸指针持有、MaybeUninit、Pin 投影及非受检访问须有适用安全论证。[15][16]

显式固定溢出检查、panic 策略、LTO、codegen units 和 CPU 特性；panic=abort 若改变原可恢复失败或清理行为，则不等价。测试构建与发布构建都验证业务契约。[20]

### Zig 配置

优先用 comptime、显式分配器、slice、optional、精确 error set、带标签 union 与明确资源协议。defer／errdefer 只覆盖对应作用域和失败路径，持久资源仍须有完整 deinit／close／drain 协议。

按当前 master 文档，debug 和 safe 模式开启安全检查，fast 和 small 默认关闭；safe 是带优化的安全配置。默认发布基线使用安全优化模式，具体命令与选项随锁定的编译器实测确认。[6]

fast 模式、局部关闭运行时检查、ptrCast、alignCast、切片构造、手动分配与资源复制逐项审查。安全检查开启也不提供完整的生命周期或并发证明；模式名称以冻结编译器的实际接口为准。Echo 当前脚本明确使用 Debug／ReleaseFast，本机 Zig 0.17.0 标准库将其兼容映射到 debug／fast；这是工作区既有验证配置，不能据 master 文档擅自改门禁或把 ReleaseFast 当作开启默认安全检查的 safe 配置。必须同时验证 Debug 与实际交付发布产物，所有权 fail-fast 边界在两种配置均保留。

### Swift 配置

采用完整 Swift 的实际可用最新能力，优先使用 ~Copyable、borrowing／consuming、Span／MutableSpan、borrow／mutate 访问器、Ref／MutableRef、InlineArray、UniqueBox、UniqueArray 或 RigidArray，逐项确认目标运行时和编译探针。[8]–[12][30]

UniqueBox 表达堆值独占，UniqueArray／RigidArray 可避免传统 Array 的写时复制模型；它们仍存在创建或增长成本。类、闭包、类型擦除和桥接的 retain／release、分配及分派必须在 E0 热路径实测核对。[9][10][31]

启用严格内存安全诊断和适用的严格并发检查，记录安全边界及获准的人工前提。strict-memory-safety 用于暴露 unsafe 构造，并不会替代其正确性证明。[13]

禁止默认使用 -Ounchecked 或关闭独占访问保护来通过性能门禁；优化优先使用正常 -O、模块优化、专用化和合法借用表达。Unmanaged、unsafe 指针、nonisolated(unsafe) 和 unchecked 并发承诺均须说明责任及生命周期。[13][31][32]

Embedded Swift 单独列为运行时与特性配置。不得把它视为完整 Swift 的自动替代，也不得从其名称推导无分配、无引用计数或已满足 Windows 原生 I/O 交付要求；目标平台、运行时、依赖与可用特性重新验收。

## 11 C++ 与 Rust 的双向迁移

### C++ 到 Rust

类与静态接口可映射为 struct／impl 与泛型约束；RAII 独占资源映射为非 Copy 所有者及 Drop，堆值可按条件采用 Box。空值、自定义删除器、分配器及转移失败必须单独映射。

不满足 Rust 引用有效性与别名规则的 C++ 指针，不能直接转为引用；先保持必要的裸边界，再建立安全访问协议。Windows 在途缓冲区不能生成与外部读写冲突的活跃引用。

重点验收：字段释放顺序、构造失败、原始错误码、可重入性、容器地址和增长，以及是否新增 Arc／Mutex／clone／动态分派。基线无异常时用明确失败结果，禁止新增 panic 作为常规失败。

### Rust 到 C++

Box 与独占所有者可映射为 unique_ptr 或专用 RAII；非 Copy 资源删除复制操作并设计移动后状态。引用和 slice 可映射为受约束引用或视图，但须重新落实生命周期和可变别名保证。

Send／Sync、借用关系与 Pin 的前提必须转换为 C++ 的接口约束、静态检查和同步论证；“能够编译”不能验收这些保证。Rust Future／Waker／poll 协议如属于基线，须保持相应调用与调度能力，不能直接改为阻塞调用。

重点验收：Drop 与 RAII 的时机和顺序、Result 负载、panic／终止契约、初始化状态，以及目标编译器不能自动检查的悬垂和数据竞争风险。

## 12 C++ 与 Zig 的双向迁移

### C++ 到 Zig

静态类型、模板与可用编译期特性映射为 struct、comptime 类型或专用生成项。RAII 映射为显式所有者和对应清理协议，覆盖成功、失败、提前返回、取消及关闭；不能仅在创建函数写一次 defer 就声称持久资源已等价管理。

为分配器、OOM、错误负载和调用约定建立明确映射。原虚接口确需开放运行时分派时才保留函数表；原本静态的模板接口不得增加函数指针调用。

重点验收：所有者的浅复制与重复释放、defer／errdefer 覆盖、指针对齐及有效值、编译期实例集合，以及安全发布配置下的真实性能。

### Zig 到 C++

comptime 实例、显式分配器、optional 和带标签结果可映射为模板／常量表达、分配器包装、optional 与 expected／variant 或专用结果。需要生成代码时登记生成实体及来源，不改成运行时反射表以绕过模板差异。

显式 deinit／close 可由等价 RAII 包装承接，但保留原提前释放、失败清理和调用能力。Zig error set 的内部标识不能当作稳定 C++ 或外部协议错误码，使用显式共同错误表。

重点验收：切片长度、sentinel、对齐、整数溢出、union 活跃成员及句柄所有权。C++ 优化不能依赖 Zig 版本中被检查拒绝的非法输入。

## 13 C++ 与 Swift 的双向迁移

### C++ 到 Swift

值类型与静态接口优先映射为 struct 和泛型 protocol；独占资源优先映射为 ~Copyable 包装与 deinit，堆值按条件采用 UniqueBox。不能将全部 C++ 类统一改为共享的 Swift class，再把 ARC 当作等价所有权。

有界临时借用可采用 Span／MutableSpan 或生命周期受约束视图。直接 C++ 互操作必须验证导入能力、生命周期／边界注解及生成包装；Swift 6.4 的 std::span 桥接也依赖接口条件。[14]

重点验收：ARC 与写时复制是否进入热路径、泛型是否专用化、错误与字符语义，以及逃逸闭包和原生回调上下文能否存活到最后一次调用。借用视图不能靠 unsafe 强行逃逸后用于异步 I/O。

### Swift 到 C++

~Copyable、UniqueBox 和独占数组可采用对应独占 RAII 与容器；borrowing／consuming 和借用访问器须保持调用能力、资源转移和无隐式复制的要求，不能只保留函数名。

原 Swift class 的身份与共享生命周期必须保留，按实际契约选择共享或侵入式计数；weak 的失效处理、unowned 的访问前提及循环关系分别映射。将 class 一律变成值类型会改变身份和别名关系。

重点验收：ARC 的释放语义、Array 的写时复制、String 的字符与索引、typed throws 的负载，以及 actor／executor 的隔离和调度。禁止通过改成普通线程共享对象消除原隔离保证。

## 14 Rust 与 Zig 的双向迁移

### Rust 到 Zig

struct、enum、泛型、Option 和 Result 可用对应值类型、tagged union、comptime、optional 与显式结果表达。含诊断负载的 Rust Error 不能只映射为 Zig 错误标签。

Rust 的借用、非 Copy 资源、Send／Sync 和 Pin 必须转换为可审查的拥有者、访问及回收协议。slice 的指针与长度即使相同，也不能证明存活与独占访问。不能通过扩大裸指针暴露范围保存接口形状。

重点验收：所有者浅复制、失效借用、Drop 遗漏、共享可变访问和 OOM。若项目要求与来源相当的静态保证，须补足获准检查或证明，否则该方向不通过。

### Zig 到 Rust

comptime 数据与实例映射为 const、泛型、宏或受控生成项；显式拥有者可映射为资源包装与 Drop，前提是原释放时机和失败清理不变。显式分配器及分配失败行为不能被默认全局分配策略抹去。

将来源指针或 slice 转为 Rust 引用前，核对对齐、初始化、合法值、存活期限和别名；无法成立时保持局部裸表示并封装其访问，不伪造多个 &mut。

重点验收：tagged union 状态、原始错误码、sentinel、整数策略、UnsafeCell 使用及安全封装。禁止通过 Arc、RefCell 或 clone 自动补偿不清楚的资源协议。

## 15 Rust 与 Swift 的双向迁移

### Rust 到 Swift

值类型和静态 trait 可映射为 struct 与泛型 protocol；独占资源用 ~Copyable／consuming，Box 按条件用 UniqueBox，Vec 按容量和分配条件选择 UniqueArray、RigidArray 或专用包装。

借用可采用 borrowing、Span、Ref／MutableRef 及生命周期约束，但不能假定它们可表达 Rust 所有多生命周期和别名关系。Ref 的具体表示也不是可直接对外承诺的裸指针 ABI。[11]

重点验收：Pin 对应的地址与回收前提、Send／Sync 与 Swift 并发契约、Result 错误负载，以及泛型、借用访问器和容器实际成本。async 语法不能授权引入新的 Task／actor 执行器。

### Swift 到 Rust

~Copyable 和独占容器可映射为非 Copy 包装、Box、Vec 或有界存储。Swift class 依原共享及跨线程契约选用 Rc、Arc 或专用共享实现；它们不自动保持对象内部的隔离协议。

typed throws／结果值映射为 Result 并保留负载和副作用。Array 写时复制不能自动改为 Vec 深复制，String 的字符计数与索引也不能变成字节索引而仍声称语义等价。

重点验收：借用访问器的读写能力、Span 有效期、类身份与 weak／unowned、deinit 时机，以及 actor／Task／executor 的执行次序与取消协议。不得以换成默认异步运行时解决架构对应问题。

## 16 Zig 与 Swift 的双向迁移

### Zig 到 Swift

值类型、tagged union、optional 与显式失败可采用 struct、enum、Optional 和 typed throws／结果；错误负载与原始码明确保留。comptime 的已实例化行为采用实际可用泛型、宏或受控生成项表达。

显式独占资源用 ~Copyable 包装及对应清理，借用视图用 Span／MutableSpan 或受约束包装。非拥有的 Zig 句柄值可以复制，拥有资源的浅复制必须按原契约区分，不能把所有值统一变成非复制类型。

重点验收：显式分配器及 OOM 行为、原生指针存活、defer 清理、整数策略，以及 Swift ARC、闭包逃逸、桥接和容器增长。不能把在途裸缓冲区替换为会失效的临时借用。

### Swift 到 Zig

非复制独占类型转换为显式拥有者及释放协议；共享 class 的计数、对象身份、weak 和循环关系须有对等实现，不能仅把字段复制到普通 struct。动态 protocol 若属于开放接口，须保留其运行时能力。

Span、Ref 和 borrowing 对应的安全前提必须转为目标可执行的访问约束与生命周期证据。Zig slice 本身不继承 Swift 借用系统的全部保证；typed throws 的诊断负载也不能只剩 error set 标签。

重点验收：deinit 与显式 deinit 的释放次数、初始化路径、跨线程隔离、引用计数成本，以及安全优化构建的越界、溢出和非法状态检查。

## 17 Windows 原生 I O 与跨语言边界

保持原 IOCP、RIO 或 I/O Ring 后端、线程拓扑、队列、批处理、槽位归属、完成分派和背压。语言提供 async／await、协程或新的 I/O 抽象，不意味着迁移必须使用它们；使用时须证明原调度与成本契约不变。

请求生命周期须区分准备、提交、立即完成、在途、取消请求、最终完成、通知消费及回收，并为每种 API 明确允许的分支。并非所有 API 都会为所有提交情形产生同样的完成通知。

CancelIoEx 返回不表示目标请求已经全部完成；OVERLAPPED 及其关联资源须保持到规定的完成条件。异步 ReadFile 的 ERROR_IO_PENDING 表示等待完成，缓冲区必须遵守 API 的有效期与使用限制。[26][27]

RIO 注册缓冲区须按其 API 管理注册、访问和注销；I/O Ring 的能力和操作支持通过目标系统查询与探针确认。不能仅凭安装了新 SDK 就假定部署系统支持所需 API，也不能把 IOCP 的取消规则套到 RIO 或 I/O Ring。[28][29]

四种语言都必须保持同一引擎边界：原生句柄、请求槽、注册缓冲区和完成队列状态归原定拥有层；业务层使用共同约定的业务事件。不能仅在一种实现中隐藏或暴露这些状态，却声称抽象统一。

共存默认采用可验证的 C ABI 包装、外部协议或独立程序差分。C++／Swift 直接互操作可在实际支持范围内采用。Rust 默认布局、Zig 普通 struct、Swift 原生布局和 C++ 非平凡类均不自动跨语言兼容。[14][17]

边界记录字段布局、尺寸、对齐、端序、调用约定、错误表示、回调有效期、分配与释放配对。禁止把 Rust Result、Zig error union、Swift 原生结果或任意 C++ 类的内部表示直接作为共同 ABI。

C++ 异常、Rust panic、Swift 失败与 Zig panic 均在批准边界内处理，不跨越不允许展开的 ABI。分配者默认提供匹配的释放入口；回调释放前先证明外部不会再次调用。桥接复制、装箱、ARC 与间接调用进入性能账目。[17]

## 18 实施阶段与验证流程

### 阶段 A 对等实现

冻结源码、共同契约、工具链、目标平台、映射、E0 范围和安全要求。选择低依赖模块或可端到端验证的切片，先设计目标语言的所有权、错误、资源和地址表示，再实现。

局部直译和必要底层操作可以采用，须记录依据。不以无意义的非惯用代码为目标，也不把 unsafe、trait、comptime 或 deinit 自动登记为技术债。

### 阶段 B 受限语言惯用化与成本优化

在已冻结的结构内改善命名、局部控制流、专用化、借用表达、固定容量存储及检查消除。每项变更核对副作用、分派、释放、同步与成本，完成针对性复验。

通用项目可按预先定义的切片交替 A／B；Echo 工作区每轮必须先完成目标语言的全部计划内源码修改、语义与架构对齐和静态复审，再统一运行格式、编译与测试，不能在尚有计划内源码对齐未完成时提前编译测试。所有权和生命周期不能推迟到 B 再处理；不能通过更换线程或队列模型把成本优化混入语言惯用化。

### 阶段 C 共同架构演进

只有明确批准改变对应约束后，才可重组模块、合并抽象、调整共享模型或替换执行器。作为独立范围管理，并同步共同契约及适用实现。

### 验证顺序

1. 冻结共同契约、映射、实际工具链与配置，完成计划内源码及静态复审；先审查实体、文件、架构、所有权和成本清单。
2. 源码阶段完成后统一格式化，构建特性探针及完整产物；Echo 顺序为 `format.ps1` → `build_release.ps1` → `build_debug.ps1`，两种构建均包含 CTest 与 reset storm。
3. 运行共同契约、差分、边界、故障、模糊和生命周期测试。
4. 核对并发状态转换、完成次数、事件偏序和回收前提。
5. 在目标 Windows 系统运行安全配置与最终发布配置。
6. 按冻结的负载与统计规则完成成本和性能门禁。
7. 保留源码、产物、原始数据及版本组合，验证回退或并行同步。

统一验证发现问题时，先定位根因并修复目标语言源码，再运行必要门禁。用户未明确要求时，不修改 PS1、构建脚本或测试门禁代替源码修复，不修改测试预期迁就实现；已明确授权的门禁补齐须保持契约与失败判定。故障子进程一律使用有界等待，禁止无限 `-Wait`，超时即判失败。所有门禁通过后才提交／推送；完成时检查只有 `main`、一个工作目录、远端同步且没有本次遗留改动。

Echo 抽象重构依次通过：P0 端到端故障注入与全线程 Join 屏障；Client Core／Transport／Runtime 及无原生依赖的 Scheduler；Server 独立 UDP Engine 与对应事件契约；Event／Action／Lifecycle／错误／关闭状态机逐函数对齐；相同事件序列的跨语言抽象契约测试；最后才进行正式性能基线。已完成步骤须有证据，后续语言对齐不得跳过对应门禁。

精确比较协议字节、错误码、退出码及规定文本。时间戳、地址和合法的非确定性仅按事前规则归一化，不为已经发现的差异临时扩大豁免。

ASan 等工具按其覆盖检测内存缺陷；Miri 用于其支持的 Rust 核心逻辑；当前 Clang TSan 支持平台清单不含 Windows。不能假定任一工具覆盖全部语言、FFI 或 Windows I/O；缺口必须由适用的静态论证、故障测试和原生验证补足。[23]–[25]

差分全部通过只证明已执行测试集通过。并发正确性还需要协议论证；安全构建通过后仍须验证最终优化发布产物，性能验收使用准备交付的同一发布配置。

## 19 验收与阻断规则

| 门禁 | 必须通过的标准 |
| --- | --- |
| 工具链 | 版本、快照、语言模式、库、SDK 和特性探针可重现 |
| 语义 | 无未处置契约差异，规定的确定性结果精确一致 |
| 抽象 | 实体、职责、接口能力、分派与所有权映射完整 |
| 文件 | F1 双向清单完整，例外获准且未隐藏业务迁移；Echo Rust／Zig Client 9、Server 8，Swift 业务源码 8／7 加真实模块声明例外，无空占文件 |
| 架构 | 边界、依赖、状态归属、线程与队列关系保持；Pure Engine 无原生 Transport 依赖，同输入事件的 Action、快照与账本对等 |
| 安全 | 适用不变量与维护者明确，无未解释的安全前提缺口 |
| 生命周期 | 失败、取消、关闭、完成、排空与复用协议通过；先 Join 全部再集中检查释放，释放内部 guard 有正向与顺序证据 |
| 成本 | E0 成本预算满足，例外完整且不被隐藏 |
| 实测 | 抽象门禁先通过，二进制 SHA-256 与优化模式已冻结，失败轮次完整保留，绝对 SLA 和冻结的比较门禁分别通过 |
| 工程 | 全部计划内源码及静态审查先完成，统一格式、Release／Debug 门禁通过，豁免有依据 |
| 集成 | 替换可回退，并行可重现共同契约对应的版本组合 |

映射率分母由冻结的清单确定，所有辅助项和例外纳入审查。禁止通过删除难以迁移的实体、隐藏冷路径或降低输入范围来制造验收通过。

有以下任一情形必须阻断集成：未定义行为或数据竞争、在途资源提前回收、错误负载丢失、未批准架构漂移、热路径隐式成本超预算，以及证据不足的性能结论。某个方向不通过时，记录具体原因、可行替代及约束变更需求，不牺牲安全或语义换取速度。

## 20 工件模板与持续维护

### 迁移清单

```text
项目及模式：替换或并行
共同契约版本：
来源语言 源码版本 工具链：
目标语言 源码版本 工具链：
目标 Windows SDK CPU 与运行时：
最新特性 探针与快照提交：
映射策略：F1 及已批准例外
实际依赖解析提交（Echo Rust 不提交锁文件）：
源码阶段完成及静态复审证据：
Event Action Completion Lifecycle 与释放顺序映射：
热路径 负载范围 容量与 E0 预算：
安全保证 维护者与证明要求：
绝对 SLA 比较预算 统计判定：
验证证据 产物与回退安排：
产物 SHA-256 优化模式 完整构建参数：
全线程 Join 释放 guard 正向与顺序证明：
```

### 实体与成本映射

```text
稳定 ID 及来源／目标位置：
共同职责 与所属组件：
接口 调用能力 分派方式：
所有权 借用 复制 转移与失败保证：
状态 线程 同步 完成与回收：
文件及语言关联项：
成本：分配 复制 RC 分派 锁 调用 批量
表示差异 等价依据与局部安全前提：
特性探针 测试 原始测量与代码证据：
ADR 技术债及例外：
```

### 局部安全依据

```text
操作边界 内存 句柄或回调来源：
长度 对齐 初始化 有效值与存活期限：
别名 可变访问及线程限制：
地址稳定 发布 完成 取消与释放条件：
各项前提维护者及不被合法调用破坏的依据：
安全检查及保留／消除检查的证明：
故障用例 与批准的共同模式：
```

ADR 记录背景、现行约束、决策、替代方案、安全与成本依据、批准人、验证和回退。写 ADR 不等于获得突破硬约束的许可。技术债记录具体问题、影响、限制、责任人和退出条件；正常的底层封装不自动构成技术债。

架构负责人冻结对应与同步边界；语言负责人维护表示和特性探针；安全负责人审查不变量及底层边界；验证负责人维护共同测试与性能判定；构建负责人保存可重现版本组合。

多实现并行维护时，每次共同变更先更新契约与映射，再更新全部适用实现，最后使用同一组外部测试和负载统一跑门禁。登记临时不同步状态；未同步版本不能声明彼此等价。语言内部优化也必须通过既定结构、安全和性能门禁。

## 21 官方技术依据

本规约的 E0、流程和门禁是项目规范。以下官方资料支持相关语言、编译器和 API 事实，不表示这些来源承诺所有迁移方向均可无成本实现。原资料于 2026 年 10 月 12 日登记；2026 年 10 月 14 日复核了发布／开发通道、Swift 6.4.1 公告与 Windows 取消语义，其余链接不据此声称全部重新核验。项目验收仍以冻结的实际工具链和目标系统为准。

- [1] [LLVM 当前发布与开发通道](https://llvm.org/)
- [2] [Clang C++ 语言特性实现状态](https://clang.llvm.org/cxx_status.html)
- [3] [GCC 当前发布与开发通道](https://gcc.gnu.org/)
- [4] [Rust 1.99.0 发布说明](https://blog.rust-lang.org/2026/10/01/Rust-1.99.0/)
- [5] [Zig 当前发布与 master 下载](https://ziglang.org/download/)
- [6] [Zig master 语言参考与优化安全模式](https://ziglang.org/documentation/master/)
- [7] [Swift Windows 发布与开发快照](https://www.swift.org/install/windows/)
- [8] [Swift 6.4 发布说明](https://www.swift.org/blog/swift-6.4-released/)
- [9] [Swift SE 0517 UniqueBox](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0517-uniquebox.md)
- [10] [Swift SE 0527 RigidArray 与 UniqueArray](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0527-rigidarray-uniquearray.md)
- [11] [Swift SE 0519 Ref 与 MutableRef](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0519-ref-mutableref-types.md)
- [12] [Swift SE 0507 borrow 与 mutate 访问器](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0507-borrow-accessors.md)
- [13] [Swift SE 0458 严格内存安全检查](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md)
- [14] [Swift 与 C／C++ 的安全互操作](https://www.swift.org/documentation/cxx-interop/safe-interop/)
- [15] [Rust 未定义行为与安全封装责任](https://doc.rust-lang.org/reference/behavior-considered-undefined.html)
- [16] [Rust Pin 契约](https://doc.rust-lang.org/std/pin/index.html)
- [17] [Rust FFI 与展开边界](https://doc.rust-lang.org/nomicon/ffi.html)
- [18] [Rust Drop 与释放顺序](https://doc.rust-lang.org/std/ops/trait.Drop.html)
- [19] [C++ 标准草案 析构规则](https://eel.is/c++draft/class.dtor)
- [20] [Cargo 发布配置与溢出检查](https://doc.rust-lang.org/cargo/reference/profiles.html)
- [21] [Clang 生命周期安全分析](https://clang.llvm.org/docs/LifetimeSafety.html)
- [22] [Clang C++ Safe Buffers](https://clang.llvm.org/docs/SafeBuffers.html)
- [23] [Clang AddressSanitizer](https://clang.llvm.org/docs/AddressSanitizer.html)
- [24] [Clang ThreadSanitizer 与支持平台](https://clang.llvm.org/docs/ThreadSanitizer.html)
- [25] [Miri 及其适用范围](https://github.com/rust-lang/miri)
- [26] [Windows CancelIoEx](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelioex)
- [27] [Windows ReadFile](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-readfile)
- [28] [Winsock RIORegisterBuffer](https://learn.microsoft.com/en-us/windows/win32/api/mswsock/nc-mswsock-lpfn_rioregisterbuffer)
- [29] [Windows QueryIoRingCapabilities](https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-queryioringcapabilities)
- [30] [Swift SE 0377 参数所有权修饰符](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0377-parameter-ownership-modifiers.md)
- [31] [Swift 编译器性能优化说明](https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst)
- [32] [Swift 独占访问保护](https://www.swift.org/blog/swift-5-exclusivity/)
- [33] [Swift 官方发布负责人：Swift 6.4.1 发布公告（2026-10-13）](https://forums.swift.org/t/announcing-swift-6-4-1/90029)
- [34] [Microsoft 官方 windows-rs 仓库](https://github.com/microsoft/windows-rs)
