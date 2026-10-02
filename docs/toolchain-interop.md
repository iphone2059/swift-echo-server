# 工具链与验证证据

## 工具链

- Swift 6.4（`swift-6.4-RELEASE`），目标 `x86_64-unknown-windows-msvc`，Windows SDK 由工具链的 Windows 平台包提供。
- `Package.swift` 使用 `swift-tools-version: 6.4` 与 `swiftLanguageModes: [.v6]`；无第三方依赖，核心模块与正式可执行目标都启用 `.strictMemorySafety()` 并把 `StrictMemorySafety` 警告提升为错误，链接 `Ws2_32`。
- 产品依赖 Swift 6.4 运行库（`swiftCore.dll`、`swiftWinSDK.dll`、`swiftSynchronization.dll`、`Foundation.dll`、`FoundationEssentials.dll` 及其传递依赖）与 MSVC x64/UCRT 运行库。

## 测试运行后端

Swift 6.4 Windows 默认构建后端的 Release 测试运行器会遗漏测试 DLL，导致发现零个测试。`build.ps1` 只在单元测试阶段采用 `swift test -c <config> --build-system native`，并用 `Test run with N tests ... passed` 断言 N>0，零测试即失败；正式服务端构建仍使用默认后端。Debug 同样使用 native，两个配置执行同一套 Swift Testing 用例。

## 语言与编译器边界（本轮实测）

- `borrowing` 参数不能被 `&&`、`||` 右侧的 autoclosure 捕获（`error: 'options' cannot be captured by an escaping closure since it is a borrowed parameter`）。UDP 循环因此把 `/w` 到期时间预先算成一个局部值，再与停止标志做布尔组合。
- 把 `~Copyable` 的固定存储绑定到局部变量、再在函数尾部读取其属性以延长生命期，会让 6.4 的 `MoveOnlyChecker` 触发 `FieldSensitivePrunedLiveness.h` 断言并导致编译器崩溃。UDP 槽位表与通知 `OVERLAPPED` 因此改为显式分配加作用域释放，语义与基线的 `HeapAlloc` + owner 相同。
- 严格内存安全要求：`@unsafe` 结构体的初始化与属性读取、unsafe 指针与 `nil` 的比较、`~SOCKET(0)` 比较、取值范围含 unsafe 的赋值都要显式 `unsafe` 标记；同一表达式内不能在中缀运算符右侧另起 `unsafe`。
- 由 unsafe 表达式得到的指针对后续“绑定/返回”仍带标记：`let candidate = unsafe UnsafeMutablePointer<T>(bitPattern:)` 之后必须写 `guard let value = unsafe candidate, ...` 与 `return unsafe value`；少写标记会被 `StrictMemorySafety` 拒绝（本仓库的地址校验辅助函数即此写法）。

## 把关脚本

| 脚本 | 作用 |
|---|---|
| `ces_source_policy.ps1` | 源码策略：禁止普通 send/recv 族数据面、`@unchecked Sendable`、相邻项目引用、Testing 进入 Sources、NUL 字节；要求 RIO/所有权符号存在；核对 Package.swift 的工具链版本、无外部包、每目标严格内存安全；审查 `@safe` 白名单 |
| `ces_memory_safety_checks.ps1` | 用真实编译器验证 6 个安全正反例：未标记 unsafe 的读写与存储必须被拒，arena 作用域借用必须通过 |
| `ces_ownership_compile_tests.ps1` | 所有权正反例：`~Copyable` 复制/消费后使用/借用中销毁/配置复制必须被拒 |
| `ces_verification_gate_tests.ps1` | 回归把关脚本自身：合成诊断必须按消息而非文件名识别，额外 `@safe` 必须被拒 |
| `ces_process_tests.ps1`、`ces_extended_process_tests.ps1` | 黑盒进程验收：TCP/UDP 回显与字节对账、参数矩阵、端口冲突、空闲超时、`/w` 受控停止、Ctrl+Break 受控停止、宽字符参数、排空 |
| `ces_interop_tests.ps1` | 互操作：用已验收的 `swift-echo-client` 与 `cpp-echo-client` 驱动本服务端，逐字节校验并核对双方 `bytes` |
| `ces_standalone_check.ps1` | 复制到独立目录、排除原构建缓存后重跑完整验证 |

## 实测证据

- `swift build`（Debug/Release）无错误、无警告；核心模块在 `-strict-memory-safety` 下通过。
- `swift test --build-system native`：23 个 Swift Testing 用例全部通过（契约解析、数值运算、通知迁移与放弃、UDP 槽位地址校验、定时器堆、生命周期、统计累加）。
- 源码策略、6 个安全正反例、8 个所有权正反例、验证门回归全部 PASS。
- 互操作：`swift-echo-client` TCP 500 次/8 会话、UDP 200 次/4 会话；`cpp-echo-client` 同规模；客户端退出码 0，TCP 客户端与服务端 `bytes` 完全相等（2048000 字节）。
- 进程验收与扩展场景见 `build.ps1` 输出。
- 复审修复后的完整把关（Debug 与 Release）：22 个单元用例、8 个基础进程场景、9 个扩展场景、4 个互操作场景、源码策略、6 个安全正反例、8 个所有权正反例、把关自测全部 PASS；`tcp-1000sessions`、10000 会话、连接建立速率与定时器堆微基准见性能文档。
- 饱和停止实测（第二轮）：满速 UDP 洪泛（8 发送者 × 1200 B，服务端 5 s 处理 143 万完成）下 Ctrl+Break 1.07 s 退出、`outstanding=0`、stderr 为空；TCP 无读突发（8 客户端 × 64 KiB）下 Ctrl+Break 0.99 s 退出、`active=0`、stderr 为空；`/w` 到期路径同样在期限内结束。
