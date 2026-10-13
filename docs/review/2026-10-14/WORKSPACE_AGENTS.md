# 工作区约定（AGENTS.md）

本文件是本工作区所有 agent（含 Codex 及后续任何自动化）必须遵守的硬性约定。工作区根目录
`C:\Users\Administrator\echo-project` 不是 git 仓库，因此本文件只存在于本机；各语言仓库各自独立。

## 分支与工作目录

每个仓库 (`cpp-echo-client`、`cpp-echo-server`、`rust-*`、`swift-*`、`zig-*`) 只允许：

1. 只保留一个分支 `main`，直接在仓库目录的 `main` 上修改，不创建额外分支或 worktree。
2. 开始修改前和推送完成后，确认 `main` 与 GitHub 的 `origin/main` 一致
   （`git rev-list --left-right --count main...origin/main` 结果为 `0 0`）。修改、验证和提交期间允许暂时不同步。
3. 保留用户已有改动，避免覆盖其他正在进行的工作。

## 改代码的收尾流程（每次必须完成）

1. 在仓库目录的 `main` 上改代码；
2. 运行仓库自带门禁：`format.ps1` → `build_release.ps1` → `build_debug.ps1`（两者都跑 CTest 与 reset storm）；
3. 编译和测试全部通过后，提交到 `main` 并推送 `origin/main`；门禁失败时不得推送；
4. 确认 GitHub 远端 SHA 与本地 `main` 一致，工作目录没有本次遗留的未提交改动；
5. 任何未提交的实验内容若需要保留，先归档到
   `C:\Users\Administrator\echo-project\.superpowers\` 下的压缩包/bundle，再清理：
   本地不再长期保留游离分支、游离 worktree 或未提交改动。

## 所有代码修改的阶段顺序

- 先完成目标语言的全部计划内源码修改、语义与架构对齐及静态复审，确认源码阶段完成后，才统一运行格式化、编译和测试；不得边做尚未完成的对齐修改边提前编译测试。
- 用户未明确要求调整脚本时，不主动修改 PS1、构建脚本或测试门禁来替代源码修复，也不得修改测试预期来迁就实现。
- 统一验证发现问题时，先定位根因并修复目标语言源码，再重新运行必要门禁；所有门禁通过后，才提交并推送 `main`。
- 此规则适用于本工作区后续所有同类改代码任务，优先于技能中要求提前执行测试的默认流程。

## Rust Windows 依赖

- `windows` 依赖追踪官方 `microsoft/windows-rs` Git 仓库默认分支，不指定固定 `rev`。
- 不保留或提交 `Cargo.lock`；两个 Rust 仓库均忽略该文件。
- 构建前清理生成的锁文件并更新 Git 依赖，验证结束后再次清理锁文件，以持续追踪最新状态。
- Rust 对齐任务先完成全部 Rust 源码修改和静态审查，再统一编译、测试；不以修改 PS1 脚本代替源码修复。

## 检查（随时可执行）

```powershell
foreach ($d in Get-ChildItem -Directory | Where-Object { $_.Name -match '-(echo-client|echo-server)$' }) {
  $b = @(git -C $d.FullName for-each-ref --format='%(refname:short)' refs/heads)
  $w = @(git -C $d.FullName worktree list).Count
  $c = git -C $d.FullName rev-list --left-right --count HEAD...origin/main
  "{0}: branches=[{1}] worktrees={2} vs-origin={3}" -f $d.Name, ($b -join ','), $w, $c
}
```

完成后的期望输出：`branches=[main] worktrees=1 vs-origin=0 0`。

以上直接修改 `main`、编译测试通过后再推送的流程，依据用户于 2026-10-07 的最新要求，
替代此前必须使用 worktree 的约定。切换时已有的 worktree 应在本次任务结束前归档并清理。

## 跨语言抽象一致性（Rust ↔ Zig 重构方法论）

目标不是「Zig 能正确运行」，而是两份代码在**逻辑架构上逐模块、逐状态机、逐接口可相互映射**，
语言差异只允许出现在具体实现中。本节为硬性约定，优先于「看起来类似即可」的判断。

### 分层与依赖方向

```
Application / Coordinator     入口、参数、Worker 创建、停止、Join、最终统计
Worker Runtime                事件循环、完成处理调度、Action 执行
Pure Engine                   Session / Connection / UDP / Acceptor 状态机、Scheduler、Timer、Statistics
Transport                     RIO 请求、ConnectEx / AcceptEx、Completion、代际管理
Native / Resource Ownership   Win32、Winsock、IOCP、RIO、Socket、CQ、RQ、OVERLAPPED、Arena
```

执行链在两种语言中必须完全相同：

`Transport → Event → Worker Runtime → Pure Engine → Action → Worker Runtime → Transport`

**Pure Engine 与 Transport 不得相互依赖**，由 Worker Runtime 协调。Scheduler 不得读取原生状态
（Slot、RQ、OVERLAPPED、outstanding 计数）；drain 之类的原生判定由 Transport 层作出后作为事件传入。

### 四类统一数据

| 类别 | 含义 |
| --- | --- |
| `Event` | 已完成原生所有权核算的事件，交给 Pure Engine |
| `Action` | 纯业务决策，交给 Worker Runtime 执行 |
| `Completion` | 原生完成记录的规范化表示 |
| `Lifecycle` | 可释放性与退出状态 |

两条不可违背的不变量：

1. **取消 Socket 不等于完成 I/O。** 关闭 socket 只是发起取消，不归还 provider 仍持有的操作；
   outstanding 只能由 Completion 递减。
2. **只有全部相关 Completion 都被收到并核算，才能发布 `GenerationDrained`。**

### 错误表示必须同层一致

同一层不得一边用返回值表达错误、另一边用悄悄修改全局状态表达同一错误，除非 Worker Runtime
能保证两者控制流与终止行为完全相同。涉及 Windows 仍持有 OVERLAPPED/RIO 资源的不变量失败，
**必须在释放边界之前 fail-fast**，且检查要放在释放函数内部，使任何调用方都无法绕过。

### 允许的差异 与 必须一致的部分

允许不同：`Drop`/RAII ↔ `defer`/显式释放；`Result`/`Option` ↔ Error Union/Optional；
Trait 泛型 ↔ `comptime` 静态专门化；`Arc`/Atomic ↔ 显式所有权/Atomic；
`windows-rs` ↔ 直接 Win32 ABI 声明；`Vec`/`Box` ↔ 预分配 Slice/Allocator；
`std::thread` ↔ `CreateThread`；`enum`/`match` ↔ `enum`/`switch`。

必须一致：状态集合与转移条件、事件优先级、操作归属计数、取消语义、资源释放顺序、
外部可观察结果（stdout、统计账本、错误分类、退出码）。

### 文件结构与抽象载体

Client 9 个、Server 8 个源文件保持不变。**为每个抽象单独建文件不是目标**——统一的是各文件
内部的职责边界与模块契约。新增的逻辑类型（如 `WorkerCore`/`RioTransport`/`WorkerRuntime`、
`UdpEngine`）放进既有文件。

### 拒绝标准（重构不得引入）

热路径上的虚表或动态分派；每次调用的堆分配；为了「抽象」而增加文件或参数搬运。

### 验收标准

| 条件 | 要求 |
| --- | --- |
| 分层一致性 | 对应层职责完全一致 |
| 依赖方向 | Pure Engine 不依赖原生 Transport |
| 状态机 | 相同状态集合、事件与转移条件 |
| 完成处理 | 相同的事件核算与 Action 顺序 |
| 资源所有权 | 统一释放条件，语言机制可不同 |
| 测试可替换性 | 纯 Engine 可独立测试，Transport 可由测试实现替换 |
| 源码数量 | Client 9、Server 8 |
| 性能 | 不引入不必要的动态分派或热路径分配 |
| 二进制契约 | 输出、统计、错误、退出码一致 |

抽象一致性是**正式性能基线之前的硬性门禁**，不以「端到端跑通」代替。

### 重构顺序（按此推进，一次一步）

1. 完成 P0 端到端故障注入与全线程 Join 屏障（先 join 全部 Worker，再集中检查释放不变量）。
2. Zig Client 拆分 `WorkerCore` / `RioTransport` / `WorkerRuntime`，保持 Scheduler 不依赖 Win32。
3. Zig Server 独立 `UdpEngine`：Slot 状态、outstanding、重发/Reset/错误转移、统计移出原生循环；
   必要时同步调整 Rust，使两侧事件契约一致。
4. 统一 Event / Action / Lifecycle / 错误分类 / 关闭状态机；逐函数比较前置条件、后置条件与
   事件顺序，而不是只比较成功路径结果。
5. 跨语言抽象契约测试：相同输入事件序列 ⇒ 相同 Action 序列、状态快照与统计账本。
6. 以上通过后，才启动正式性能基线。

### 基准与验证纪律

- **冻结构建模式与二进制身份**：`zig-out\bin` 被 Debug 与 ReleaseFast 共用，测量前必须按
  `build-manifest.json` 校验 SHA-256 并确认 `optimize_mode`；不得混用两种模式排名。
- **子进程故障用例一律用有界等待**，禁止无期限 `-Wait`；超时即判失败，否则回归测试会挂住门禁。
- **失败轮次原样保留为失败记录**，不得补跑到取得满意数据为止。
- **每个 fail-fast 断言都要有正向对照**，否则一个拒绝所有输入的 guard 也能「通过」。
- **释放顺序类修复必须有顺序证明**：例如把状态放在栈上、让「先释放」会触碰非堆地址，
  从而无法产生那条干净且具名的边界信息。
