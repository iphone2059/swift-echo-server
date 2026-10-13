# Swift 对齐暂停快照 — 2026-10-14

用户要求立即暂停对齐，并将当前代码提交 GitHub，以便换电脑审查。本次提交是 WIP 审查快照，按该最新要求在完整门禁之前提交；不表示源码对齐、编译、测试或性能验收已经通过。恢复工作时仍应遵守工作区正常流程。

两个 Swift 仓库都停留在原有 main，未创建分支或 worktree；暂停前所有写代码的 agent 已停止。

## 当前代码状态

- Client 的 Sources 已扁平化，直接包含 contract.swift、types.swift、payload.swift、metrics.swift、native.swift、internal.swift、engine.swift、main.swift，共 8 个文件。
- Server 的 Sources 已扁平化，直接包含 contract.swift、types.swift、native.swift、engine.swift、internal.swift、server.swift、main.swift，共 7 个文件。
- Sources 不包含 CECClientCore、CESServerCore、swift_echo_client、swift_echo_server 或其他子目录。Package.swift 保留模块身份，通过显式、不相交的 source 清单引用同一扁平目录。
- Client 实现者已提交源码阶段交接报告；独立复审尚未完成。Server 源码与测试修改保留在暂停时状态，尚未完成独立复审，也未写出最终 server-report。Server 交接确认已写入 TCP/Connection/UDP/Acceptor 状态机、原生账本、Join/释放边界、事件序列与真实 995 故障驱动；恢复时尤其需要检查 Swift 借用/不可复制 Optional、严格内存安全诊断、@c 回调签名及失败路径和事件顺序。
- 更新后的跨语言规范、计划和审查材料随两个仓库一起提交。规范中的目标要求与 README 的实现描述均需要后续代码审查和实际门禁验证。

## 未验证及未完成事项

- 本轮尚未运行 format.ps1、编译、Swift Testing、CTest、Release/Debug 门禁、reset storm 或正式性能基线。
- Server 的 CMakeLists.txt 已注册 ces_fault_process_tests.ps1，但该脚本尚未编写；这是快照中的明确未完成项，不能据此宣称完整门禁可用。
- Client 的 cec_fault_process_tests.ps1 仍是旧模式集合；尚待覆盖新 FaultDriver 模式、真实 995 完成丢弃用例、正向对照与 Join/释放顺序证明，并补齐有界等待和清理。
- 新的 Client 优化 IR 门禁、布局探针，以及两边新增的格式化、CTest、所有权、安全和 reset-storm 门禁尚需独立复审及实际运行。
- 先前 infrastructure-review.md 是当时脚本版本的审查记录。其后部分问题已有修改，需对最终脚本重新复审，不能直接视为全部已解决。
- 暂停时 Client 的 git diff --check 提示 Sources/types.swift 文件末尾有新增空行；未在暂停后继续格式化或改代码。

## 恢复顺序

1. 先审查当前快照、规范和已有报告，记录并修复源码、状态机、所有权和事件顺序的问题。
2. 补齐上列故障子进程门禁，保留三种参考实现一致契约的断言依据，不降低测试要求。
3. 两个 Swift 仓库的全部源码修改与独立静态复审完成后，统一运行 format.ps1 → build_release.ps1 → build_debug.ps1；两种构建都必须运行 CTest 和 reset storm。
4. 保留失败记录，定位根因后修源码，再运行必要门禁；全部通过后按正常流程提交推送并核对本地与 GitHub SHA。
5. 正式 E0/性能验收仍是后续独立阶段，需要冻结工具链、构建模式、二进制身份与负载。

Client 快照基线：f601de6ec451f4c0a599c34bd529e89445e71874。

Server 快照基线：bcd4d5b2fe33878028ae820dc618cb298924b910。

参考仓库快照：C++ Client 0853573、Server 68d8085；Rust Client e4efb27、Server ac8bdee；Zig Client 371b02f、Server 28b4717。
