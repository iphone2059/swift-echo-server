# Reference alignment source report — 2026-10-14

Evidence level: S0/static source review only. No format, build, unit/process test, reset storm,
commit or push was run by this agent. Root owns unified verification and repository completion.
All changes are on the existing `main`; no branches, worktrees or new production source files.

## Baselines before mutation

Each repository was fetched and checked with `git rev-list --left-right --count main...origin/main`
(`0 0`), `git branch --show-current` (`main`) and actual `git ls-remote origin refs/heads/main`.
Local main, origin/main and actual remote matched these document baselines:

| Repository | SHA | Source phase complete | Agent modifications |
| --- | --- | --- | --- |
| cpp-echo-server | 68d808503899abd0be1d6bca87795b3eca226ec7 | yes | CL-01 production guard, pure policy and existing tests/driver |
| rust-echo-server | ac8bdee80bd89731f908ef2da84baeefc92749d4 | yes | CL-01 pure policy, runtime guard, truth table and bounded process test |
| zig-echo-server | 28b471719273643681ad44ac9083099888d05e4e | yes | CL-01 listener/accepted distinction, actual fail-fast and existing tests/driver |
| zig-echo-client | 371b02fe8df35af31a651684b4f149a19e2e64bb | yes | CEC_DIAG_FILE implementation/schema test and RX documentation |
| rust-echo-client | e4efb273c7e1cf178f5f8021aef56c00de7a5a82 | yes | RX documentation only |

An initial Zig Server ls-remote and Zig Client fetch experienced schannel TLS handshake failure.
Both were retried successfully with ordinary fetch/ls-remote before any Zig mutation; no TLS
validation was disabled and no git configuration was changed. The original failures remain in
the session tool record.

## CL-01 selected contract A

Inputs are `stopping`, `failed`, `listener_valid`, `accepted_valid`. Ordered decision:

1. `stopping || failed || !listener_valid`: withdraw, close owned accepted socket using the existing
   path, return slot using the existing transition; no new network error.
2. Healthy listener but absent accepted socket: immediate fail-fast before cleanup. Exact signature:
   `AcceptEx handoff invariant failed: native_error=10038`; exit 4.
3. Healthy valid pair: unchanged context update, socket configuration, address validation, credit
   reservation and Worker handoff.

The invariant is not a new network error. Socket cancellation and Completion accounting were not
changed; valid Transit ownership, acceptance credit and normal RIO hot paths were not changed.

The source review corrects an error in the v1.0 review document: the existing Zig `.fatal` enum
did not mean immediate fail-fast exit 4. At the baseline, it called `failAndStop` (report + global
failure + stop), and server coordination classified that failure as network exit 2. It also
combined invalid listener and invalid accepted socket, making healthy listener retirement fatal.
Both discrepancies required a minimal Zig Server correction in addition to C++/Rust/Swift.

Production references (line numbers before final formatting):

- C++ pure contract: `cpp-echo-server/include/ces_engine_internal.h:69`,
  `src/ces_engine_internal.cpp:10`; native boundary `src/ces_engine.cpp:774`, production call `:866`.
- Rust pure contract `rust-echo-server/src/internal.rs:104`; runtime boundary `:3024`, handoff `:3758`.
  The pure function has no native state or reporting dependency.
- Zig pure contract `zig-echo-server/src/internal.zig:935`; native boundary `:943`, handoff `:1404`.

Tests encode an explicit independent 16-row truth table (bit 0 stopping, bit 1 failed, bit 2 listener
valid, bit 3 accepted valid). Only row 4 is fatal; only row 12 hands off; all others withdraw.

- C++ `tests/ces_engine_tests.cpp:56`; existing fault driver modes `handoff_positive` and
  `handoff_invalid` in `tests/ces_fault_driver.cpp:121` exercise the production native guard.
- Rust pure test `src/internal.rs:450`; `worker::tcp::tests::handoff_invariant_process_contract`
  at `:4359` re-executes the unit-test binary with child-only environment mode. Each child has a
  10-second deadline, then kill + wait on timeout. Positive validates healthy admission, stop,
  global failure and listener retirement; negative checks exit 4 and the exact stage/error.
- Zig `tests/engine.zig:605`; existing fault driver modes `handoff_positive` and `handoff_invalid`
  in `tests/fault_driver.zig:16` exercise the production native guard.

C++/Zig driver expected contract sent to root: `handoff_positive` exits 0 with empty stderr/stdout;
`handoff_invalid` exits 4, empty stdout, exact stage/error above. Root owns PS1 wiring; no PS1 or
CMake file was touched by this agent. Rust process coverage is directly included in existing
`cargo test`, without adding a production source file or test executable.

## CL-02b diagnostic source readiness

Zig Client previously had no CEC_DIAG_FILE writer. Added:

- `zig-echo-client/src/types.zig:34`: a fixed snapshot value and exact line serializer.
- `src/native.zig:173`, `:270`: GetEnvironmentVariableW/CreateFileW ABI and optional writer.
  Uses the shared 512-WCHAR limit and `GENERIC_WRITE`, `FILE_SHARE_READ`, `CREATE_ALWAYS`,
  `FILE_ATTRIBUTE_NORMAL`. Path/file/write failure is silent and cannot change exit classification.
- `src/engine.zig:310`: captures each started worker only after all Join operations and collective
  release checks, then writes before the first destroy. Fixed stack storage; no hot-path allocations.
- `src/types.zig:172`: exact TCP/UDP field order, saturating gap, and insufficient-buffer checks.

Exact schema (ASCII, LF, one row per started worker in zero-based order):

```text
role=client protocol=tcp|udp worker=N notify_arms=N notify_deliveries=N notify_gap=N timeout_wakeups_while_outstanding=N
```

`notify_gap = max(arms - deliveries, 0)`. Counters come from the actual transport and actual RIONotify
arm/delivery paths. No synthetic notifications were introduced. The C++ serializer is
`cpp-echo-client/src/cec_engine_internal.cpp:80`; Rust counterpart is
`rust-echo-client/src/engine.rs:19`.

Zig Server already has the identical server-role schema in `src/types.zig:231`, serializer `:241`,
writer `src/native.zig:322`; TCP captures only after all joins (`src/server.zig:202`) and writes
the snapshot at `:221` after destruction; UDP drains before finish and writes worker 0 in
`src/internal.zig:2150`. Existing snapshot validity tests are in `src/types.zig:333`.
The extra Zig Server source change concerns CL-01 only; its diagnostics required no production fix.

Both Zig diagnostic Features can now be declared by root for actual unified verifier validation.
This report does not claim T1/T2 runtime acceptance merely because source exists.

## CL-03 corrected current facts

- `rust-echo-client/docs/status.md:35`: corrected shared RX claim to per-Slot TX and RX registration
  arrays, matching `src/native.rs:759`, per-slot RX registration loop `:846`.
- `zig-echo-client/docs/parity-contract.md:108`: corrected aggregate RX registration to per-Slot
  independent `receive_registrations`, matching `src/native.zig:505`, `:521`, descriptor `:576`.
- No historical WIP/performance/failed evidence was removed or rewritten.

## Static review and remaining root work

Reviewed all agent-owned diffs and all call sites of the altered handoff function. Confirmed pure
decision/native execution separation, stop/failure/listener priority, pre-cleanup fail-fast stage,
normal path preservation, and Join-before-snapshot/destroy in Client. `git diff --check` returned 0
in all five modified repositories. Rust/Zig Client source counts remain 9; Server remain 8.
No Cargo.lock or dependency declaration was created or changed.

Remaining root work: common verifier/features metadata, C++/Zig fault PS1 pair wiring, independent
review, unified format/Release/Debug/reset gates, exact binary identity freeze and acceptance,
then commit/push/remote and clean-tree checks. Rust gates must refresh the default-branch
`windows-rs` Git dependency and remove generated Cargo.lock before and after validation.

No performance claim or overall completion claim is made by this source-phase report.
