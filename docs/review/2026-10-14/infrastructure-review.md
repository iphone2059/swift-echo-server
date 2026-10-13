# Swift verification infrastructure independent static review

Date: 2026-10-14. Reviewer: `/root/gate_review_v2`.

Scope: root `AGENTS.md`, `docs/superpowers/plans/2026-10-14-swift-alignment.md`, the infrastructure patch, both Swift repositories' build/format/CMake wrappers, unit and optimization wrappers, reset scripts, source policy and gate regression scripts, and their actual baseline gate dependencies. Infrastructure patch SHA-256: `145a399f0fabdb9a0dba628b142fe18b9eca85f563127072797bdddd1c15b1521`.

This review is static. No format, compiler, build, unit test, process test, reset storm or CTest command was executed. PowerShell `Parser.ParseFile` was used only to inspect syntax/AST; the 13 changed/new PowerShell scripts in scope have zero parse errors. Tool discovery and file existence checks were read-only.

## Verdicts

- **Spec compliance: CHANGES REQUIRED.** The old real build gates are preserved in CTest and zero-test success is rejected. Initial finding I1 was resolved by root during this review and independently re-read; I2 remains unresolved before the final source/gate readiness claim. The two explicitly declared owner-dependent TODOs remain pending and are not represented as completed.
- **Quality: CHANGES REQUIRED.** No Critical finding. One Important finding (I2) remains and can make a correct aligned implementation fail its Release gate. I1 and the nonblocking timeout-cleanup recommendation were resolved during review without weakening assertions.

## Important findings

### I1 — Server interop still asserts the obsolete global `/n` quota

**Status: RESOLVED by root; static follow-up verified.** Current `ces_interop_tests.ps1:176`, `:177`, `:179`, `:180` require 4000/800 echoes. The original zero-error and TCP exact byte equality checks are preserved. Byte extraction now anchors the standalone `bytes` field at `:155`–`:156`, avoiding accidental matches of the newly added `sent_bytes`/`received_bytes` fields. The following records the initial finding and retained old/new contract evidence.

Locations: `swift-echo-server/Tests/ces_interop_tests.ps1:172`, `:173`, `:175`, `:176`; registered by `swift-echo-server/CMakeLists.txt:20` in both modes.

The TCP scenarios pass `/n 500 /c 8` but require `echoed=500`; the UDP scenarios pass `/n 200 /c 4` but require `echoed=200`. Current C++/Rust/Zig all define `/n` per session, so successful totals are **4000 TCP echoes** and **800 UDP echoes**. The new Swift client already documents and tests that same per-session contract, so the retained server gate would reject the correct implementation.

Three-reference static evidence: C++ `cpp-echo-client/README.md:36` and `:38` (`/n` per session and `/n × /c`); Rust `rust-echo-client/src/contract.rs:35` and `rust-echo-client/tools/verification/test.ps1:505`; Zig `zig-echo-client/src/contract.zig:41` and `zig-echo-client/tools/verification/test.ps1:315`. Swift's existing `cec_extended_process_tests.ps1:14` and `:57` already use this interpretation.

Fix: under the user's explicit old-contract correction authorization, update all four totals to 4000/800 and retain the zero corruption/loss/network-error checks, exit checks, final drain checks, and TCP exact client/server byte equality. Prefer deriving totals from the scenario quota/session arguments so both implementations cannot diverge again. Retain the old/new assertion evidence in the alignment audit. The successful TCP client payload total is 4000 × 4096 = 16384000 bytes; do not remove byte accounting to make the case pass.

### I2 — Release optimized-hot-path gate expects a removed function

Locations: `swift-echo-client/Tests/cec_optimization_checks.ps1:9`, `:11`, `:17`; invoked by `cec_optimization_gate.ps1:8` and registered by `CMakeLists.txt:23`.

The gate requires emitted IR for `completeAttempt` and throws if none exists. Current aligned Swift source defines `CECWorkerCore.settleAttempt` at `Sources/CECClientCore/internal.swift:373`, called through the new core/runtime event path; a read-only search found no remaining `completeAttempt` declaration. Correct Release source therefore cannot satisfy the old mandatory symbol assertion as written. The wrapper otherwise preserves the old compilation flags and IR checks.

Fix: map the old completion-settlement check precisely to `settleAttempt` and review the real `CECWorkerRuntime.handleCompletion` / `dispatch` / `deliver` and `CECRioAdapter.retireRio` / send-tail path for equivalent coverage. Keep mandatory presence checks for real optimized symbols and the no-retain/release rule; do not skip missing functions or inspect only a compatibility adapter that is absent from the production path. Preserve the configuration value-witness copy rejection and dispatcher ARC rejection. The literal 288-byte full-configuration memcpy assertion at `:18` also needs static reconciliation with the final configuration layout; do not silently drop the original no-full-configuration-copy property.

## Confirmed preserved behavior

| Requirement | Static evidence/result |
| --- | --- |
| Real unit tests, not CTest placeholders | Both unit wrappers invoke `swift test -c $Configuration --build-system native`, check native exit status and require the final Swift Testing pass summary to contain a positive test count. This is the original build.ps1 implementation moved intact. |
| CTest cannot pass with zero discovered tests | Both build scripts invoke `ctest --no-tests=error` and reject a nonzero exit; configurations are restricted to debug/release. |
| Original Client gate coverage | Both ownership phases, real memory-safety compiler fixtures, source policy, synthetic gate regressions, fault-process positive/negative cases, baseline and extended process contracts are registered. Release retains optimized IR gate; new reset-storm is added in both modes. |
| Original Server gate coverage | Both ownership phases, real memory-safety fixtures, source policy, gate regressions, baseline/extended process contracts, interop and reset storm are registered in both modes. No baseline script or assertion was removed by the wrapper migration. |
| Release/Debug and failure propagation | `build_release.ps1` / `build_debug.ps1` both invoke common build.ps1 with explicit configuration and exit with its status. Build, configure and CTest failures throw; manifests are written only after those gates pass. |
| Windows tool discovery | Swift, swiftc, swift-format and pwsh are on this machine's PATH. CMake/CTest/Ninja are not; `Find-CMakeTool`'s vswhere fallback resolves VS18 Enterprise. All three exact fallback executable paths exist. |
| Bounded process fault waits | Existing client fault driver cases have 5-second waits and kill-on-timeout; new client reset runs via the existing 15-second process helper. CTest tests have 300-second outer limits and RUN_SERIAL; both reset peers use bounded task waits. No new unbounded child-process `-Wait` was introduced. |
| Client reset positive control | Reset budgets 0 and 32 use the same path. Both require echoed traffic and final active=0/pending=0, exact reset count, expected exit status and empty stderr. The reset case must recover and echo after real peers issue RST. |
| Server reset assertion strength | Retains at least half of the configured reset connections, server still running, verified byte-for-byte echo after the storm, zero exit/stderr and final active=0. It adds bounded connect/task waits and correct partial sends; none of those retained acceptance assertions were weakened. |
| Mode/binary identity | Build manifests record configuration, -O/-Onone, toolchain text, exact executable path and SHA-256 in mode-specific CTest directories. Gates receive the explicit bin path and mode. This is identity evidence, not a formal performance claim; any later measurement still must verify the manifest/hash at consumption. |
| Source policy and gate regressions | Forbidden native/non-RIO alternatives, external/unchecked compiler settings, strict memory-safety counts and negative diagnostic checks remain. Exact file-name mapping is added. Server explicitly whitelists only its two reviewed native safe owners and rejects any other @safe. Synthetic safety diagnostics remain separate from real compiler evidence. |

## Explicit owner-dependent TODOs

1. **ServerFaultDriver:** the current source policy expects `Tests/CESFaultDriver`, while the inspected Package.swift/build.ps1/CMake have not yet declared/built/registered that product. Root explicitly stated that the source owner is still writing it and root will connect its gate afterwards. This is unfinished work, not a completed feature or an additional surprise finding. Before final approval, verify target/product, build invocation, bounded subprocess cases, named boundary diagnostics and each fail-fast positive control.
2. **Client safe owner/control paths:** root explicitly stated that final exact safe owners and control file locations depend on the final source owner. Current source policy/gate regression still expects the former two declarations while the in-progress source includes additional safe owners. Preserve exact symbol/count checks after owner review; do not solve it by allowing arbitrary @safe. This remains pending and prevents a final gate-ready claim.

## Nonblocking cleanup recommendation

**Status: RESOLVED by root; static follow-up verified.** Current `swift-echo-server/Tests/ces_reset_storm_tests.ps1:128`–`:130` kills the process and checks `WaitForExit(5000)` before disposal/file removal. Root made the same improvement for server interop at `ces_interop_tests.ps1:164`–`:166`. The initial concern was kill requests termination without observing exit before removing redirected files; both reviewed paths now observe it within a bound. The normal server wait was already bounded and no acceptance assertion was changed.

## Acceptance limits

No gate success or formal E0/performance acceptance is inferred from this review. Resolve I2 and the two declared TODOs, finish source review, then perform the authorized format → Release → Debug sequence, including actual CTest/reset execution. This reviewer changed only this workspace evidence file.
