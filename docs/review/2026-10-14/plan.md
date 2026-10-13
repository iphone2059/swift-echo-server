# Swift cross-language alignment implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development. The user's AGENTS.md and explicit authorization override skill defaults requiring worktrees, early builds, per-task commits, or renewed approval.

**Goal:** Align both Swift implementations with the current C++/Rust/Zig shared contract, including the Sources file responsibilities, lifecycle, failure behavior, output and verification gates.

**Architecture:** Transport normalizes and accounts native completions before WorkerRuntime delivers Event to a pure Engine. Engine emits Action; WorkerRuntime executes it through Transport. Coordinator starts/stops workers, joins every thread, then verifies and releases resources.

**Tech Stack:** Installed Swift Windows toolchain, WinSDK, Winsock RIO, ConnectEx/AcceptEx, IOCP, Swift Testing, CTest and PowerShell.

**Spec:** `docs/CPP_Rust_Zig_Swift_Refactoring_Spec_v2.0.md`; root `AGENTS.md`.

## Global Constraints

- Edit only each repository's existing `main`; do not create branches or worktrees. Preserve pre-existing edits. Fetch and verify `main...origin/main = 0 0` before repository mutations.
- Finish all Swift source changes, semantic alignment and static review before formatting, compiling or testing. Do not change test expectations to accommodate implementation defects. The user explicitly authorized correcting stale Swift assertions only where C++/Rust/Zig agree, with retained reference evidence and regression coverage, on 2026-10-14.
- Pure Engine does not depend on Transport/native state. Scheduler does not inspect sockets, RQ, OVERLAPPED or native outstanding counters.
- Closing a socket requests cancellation. Only delivered Completion retires provider ownership. Publish GenerationDrained only after every associated completion is accounted.
- Fail-fast ownership guards are inside release functions, before release. Join every worker before centralized checks/release. Each failure assertion needs a valid positive control; release-order fixes need order evidence.
- Retain static dispatch and bounded preallocated hot-path storage, with no added per-request allocation or ARC work.
- Match Rust/Zig business file names and responsibilities. Swift has no module-index source file; `Package.swift` is the language-specific module declaration exception. Do not add empty or whole-file-forwarding index files. Client has eight Swift business files; Server has seven, corresponding to Rust/Zig nine/eight including their index.
- Sources is flat in each Swift repository: all production Swift files, including main.swift, are direct children. No CESServerCore, CECClientCore, swift_echo_server or swift_echo_client subdirectories remain. Package.swift assigns disjoint explicit source lists to the existing core and executable modules, sharing the physical Sources path.
- Keep CEC/CES module and symbol names where these are part of the existing Swift test/API contract; logical identity and file responsibility, rather than unrelated renaming, define this change.
- Run `format.ps1`, `build_release.ps1`, `build_debug.ps1` for each repository. Both build gates include CTest and reset storm. The user explicitly authorized adding/updating these scripts on 2026-10-14.
- All gates must pass before committing/pushing `main`. Afterwards verify GitHub SHA equals local main, clean status, one main branch and one worktree.
- Formal E0/performance acceptance remains a separate later stage: never infer it from functional tests or static review.

## Review Focus

1. Cancellation with a missing final completion must reach the bounded drain failure, rather than hang or free live native resources.
2. Partial worker/acceptor startup failure must preserve provider ownership until completion; every successfully created thread must join.
3. Invalid or stale completions must not retire a different generation or transfer ownership twice; bytes cannot exceed submitted length.
4. Timer expiry and queued connect/receive completion must follow the same bounded completion-before-timer arbitration as references.
5. Successful/failing TCP and UDP completions, reset recovery, worker caps, admission credits and final statistics must match the current shared contract.

## Task 1: Swift Client source and abstraction alignment

**Owner:** client implementer. **Repository base:** `f601de6ec451f4c0a599c34bd529e89445e71874`.

**Files:** `Sources/{contract,types,payload,metrics,native,internal,engine}.swift`, `Sources/main.swift`; existing Client tests/fault-driver Swift files and README as needed.

- [ ] Finish detailed comparison with `rust-echo-client/src`, `zig-echo-client/src` and current C++ baseline.
- [ ] Add focused lifecycle/event-order contract and fault tests. Correct stale assertions only under the user's narrowly authorized shared-contract update, with old/new evidence. Defer execution until both Swift source phases are complete.
- [ ] Consolidate existing source files by real responsibility into the mapped names. Native owners, arena and registration stay in native; session/scheduler/timer/worker state in internal; coordinator/core/transport/runtime in engine.
- [ ] Separate pure session/WorkerCore from RioTransport native storage and WorkerRuntime. Preserve normalized Event, Action, Completion, Lifecycle and error payloads.
- [ ] Align per-slot registration, posted-length/provider operation/generation accounting, bounded drain, notification release allowance, all-thread join and release guards.
- [ ] Align current reference runtime, output, arithmetic and failure behavior, then self-review source statically and report gaps.

## Task 2: Swift Server source and abstraction alignment

**Owner:** server implementer. **Repository base:** `bcd4d5b2fe33878028ae820dc618cb298924b910`.

**Files:** `Sources/{contract,types,native,engine,internal,server}.swift`, `Sources/main.swift`; existing Server tests and README as needed.

- [ ] Finish detailed comparison with current Rust/Zig/C++ implementations.
- [ ] Add focused pure Engine sequence, provider ownership and release-order tests without running them early.
- [ ] Consolidate real file responsibilities: pure TCP engine in engine; connection/acceptor/UDP core and worker runtimes in internal; top-level coordinator/statistics/dispatch in server; Win32 ownership/registration in native.
- [ ] Introduce independent UdpEngine and pure acceptor/connection/core contracts; native loops execute Actions and deliver already-accounted Events.
- [ ] Align per-slot RIO registration, raw provider ownership/submitted lengths, drain grace, notify allowance, release guards, all-thread Join barrier and admission credits.
- [ ] Match failure classification, topology, timer precedence and TCP/UDP output/statistics with references; static self-review and report.

## Task 3: Specification and verification infrastructure

**Owners:** spec editor for the common spec; coordinator for scripts in both Swift repositories.

- [ ] Update stale factual/project clauses in v2.0 using actual source/toolchain evidence and official sources when required; distinguish toolchain references from installed baselines.
- [ ] Add mapping and ownership evidence to repository documentation; record unresolved formal-performance evidence explicitly.
- [ ] Add `format.ps1` invoking installed swift-format and restore source-sensitive script paths after consolidation.
- [ ] Add CTest orchestration around the existing real unit/ownership/safety/process/interop checks; preserve their semantics and ensure test discovery cannot falsely pass with zero tests.
- [ ] Add bounded reset-storm verification to both release/debug gates, including client recovery and server acceptance, with no unbounded child-process waits.
- [ ] Obtain independent static review of both source changes and spec. Resolve substantive findings before starting source validation.

## Task 4: Unified gates and integration

- [ ] Verify source-phase completion and final physical file mapping.
- [ ] Per repository, run format → Release → Debug, recording complete logs and exit codes. Coordinate port-dependent tests to avoid collisions.
- [ ] If validation fails, diagnose and repair source before rerunning the necessary gates; do not weaken existing tests.
- [ ] Complete independent final review and confirm no relevant unresolved findings.
- [ ] Commit all verified repository changes on main, push origin/main and verify remote SHA, clean tree and topology.
- [ ] Retain workspace-level spec/plan/review evidence; archive experiments if any and remove temporary uncommitted repository content.
