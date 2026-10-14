# C++ corresponding module split implementation plan

> For agentic workers: Use superpowers:subagent-driven-development to implement the Client and Server source tasks, followed by independent whole-source review. The workspace AGENTS source-first/main-only rules and the user's existing authorization override early tests, worktrees and approval pauses.

**Goal:** Give both C++ implementations the same named business modules and responsibilities as Rust, Zig and Swift, with a matching real declaration header for each non-entry implementation file; main.cpp directly defines wmain without main.h or an extra entry wrapper.

**Architecture:** Client has eight implementation files and seven matching headers; Server has seven implementation files and six matching headers. The user explicitly excludes main.h and entry wrappers. Pure state machines consume normalized Events and produce Actions without importing Windows APIs. Native owns provider operations and resource lifetimes; static Worker Runtime connects the layers; Application/Coordinator owns startup, stop, all-thread Join and final reporting.

**Tech Stack:** C++/MSVC, existing CMake/Ninja, Windows Winsock RIO/IOCP, existing bounded PowerShell/CTest verification.

**Spec:** Root AGENTS.md; docs/CPP_Rust_Zig_Swift_Refactoring_Spec_v2.0.md; Echo four-language remaining-work regulation; user instruction dated 2026-10-15.

## Global constraints

- Work directly in each existing main; no branch/worktree. Verify actual GitHub main and local main before edits and after push.
- Client implementations: main, contract, types, payload, metrics, native, internal, engine. Server implementations: main, contract, types, native, internal, engine, server. All non-main implementations have same-name headers; main.cpp directly owns wmain with no main.h or cec_main/ces_main wrapper.
- Implementation files remain flat under src; their non-entry matching declaration headers remain flat under include. No empty translation units, forwarding-only files, or direct inclusion of .cpp files.
- Header-only compiler constraints and RIO layout declarations belong to the corresponding types/native module and must retain every check.
- No hot-path virtual dispatch, per-event allocation, algorithm duplication, or unnecessary argument copying.
- Close socket initiates cancellation; only Completion retires provider ownership. Publish GenerationDrained only after all operations are accounted for.
- Join every worker before checking/freeing any worker aggregate. Each release entry checks its own prerequisites.
- Preserve output fields, counters, exits, packet priority, quota, cancellation, timer anchors and CL-01 strategy A.
- Finish all C++ planned source work and static review before format, build or executable tests. Existing Swift gates are already green in the current published main; old failure logs remain historical.

## Review focus

- Stop arriving before versus after a CQ notification must preserve event/action order and timer eligibility.
- Generation reuse and late cancellation completions must preserve operation ownership, stale-completion rejection and final drain.
- Healthy invalid accepted socket must fail-fast 4/10038; legitimate stop/listener withdrawal must remain valid.
- Partial startup and fault-driver direct release must use the same production all-Join/release checks.
- Pure Engine independence must be real: Scheduler cannot consult native slots, RQs, OVERLAPPED or provider counters.

## Task 1: Client decomposition

Owner: cpp_client_modules. Files: eight src/*.cpp and seven non-entry include/*.h, existing CMakeLists.txt/compiler constraints and tests/path references, README. Produce an independent Session/Worker Core, Event/Action interfaces, native resources/normalized completion, static runtime and coordinator. Preserve the existing native fault interfaces where compatible and link test drivers normally. Record entity/function mapping and static dependency review in cpp-client-module-report.md.

- [ ] Verify synced main and preserve existing source.
- [ ] Inspect corresponding Rust/Zig/Swift modules and enumerate existing C++ entities.
- [ ] Split actual responsibilities and declarations into the eight implementation modules and seven matching headers; remove superseded files and update all references.
- [ ] Statically review state transitions, ownership and event order; add meaningful equivalent core-sequence coverage without changing existing expectations.

## Task 2: Server decomposition

Owner: cpp_server_modules. Files: seven src/*.cpp and six non-entry include/*.h, existing CMakeLists.txt/compiler constraints and tests/path references, README. Produce pure TCP/UDP/Acceptor state and corresponding static runtimes, native resource ownership, and server coordinator. Record mapping, handoff truth table and all-Join/release review in cpp-server-module-report.md.

- [ ] Verify synced main and retain current CL-01 fixes.
- [ ] Inspect corresponding Rust/Zig/Swift modules and enumerate existing C++ entities.
- [ ] Split actual responsibilities and declarations into the seven implementation modules and six matching headers; remove superseded files and update all references.
- [ ] Statically review event/action/counter ownership and release order; retain valid positive fault controls.

## Task 3: Shared review, specification and verification

Owner: root with an independent reviewer. Consume both source reports and finished source trees. Update v2.0's actual C++ mapping and explicitly approved F2 header/implementation pairs; preserve historical review checkpoints. Review both complete C++ trees before source-phase closure. Run each repository's format.ps1 -> build_release.ps1 -> build_debug.ps1 with bounded tests/reset storms and retained failures. Fix root causes before justified reruns. Commit/push only after all gates pass; verify actual remote SHA, clean trees and single-main/single-worktree topology. Any final cross-language contract or performance freeze must use these new C++ binaries rather than the earlier pre-split binaries.

- [ ] Update specification and durable progress records.
- [ ] Independent source/dependency/order review; close material findings.
- [ ] Close C++ source phase and run complete format/Release/Debug gates.
- [ ] Review fresh binary contract evidence and preserve any failed attempt.
- [ ] Commit/push and verify exact GitHub/main identity and clean task state.
