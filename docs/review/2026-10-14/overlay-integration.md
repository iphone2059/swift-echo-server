# Incoming overlay review — 2026-10-14

The user explicitly confirmed that the two untracked alignment overlays inside cpp-echo-client are review deliverables from the other computer and authorized checking and merging applicable changes. They are not C++ implementation files. Their historical baselines are the published Swift WIP snapshots d8a847a/dbaad11.

No Apply-Alignment.ps1 or Build-CompleteSourceZip.ps1 was executed. Edits were compared with the current sources and integrated individually, avoiding old-checkout replacement and extra clones/branches/worktrees.

## Client

The overlay contains one source replacement: validate send ownership and offset before subtracting in CECRioAdapter.retireRio. The current repair already covers this and additionally rejects signed negative offsets and invalid posted extent, using existing shared failure stages. Preserve the current repair and its underflow/valid-tail controls; replacing it with the overlay's new stage and unsigned-offset comment would lose consistency.

## Server

- Integrated the still-missing CESUdpEngine.markPosted aggregate bound outstanding < depth. Existing per-Slot operation/ownership guards and return-Bool failure semantics remain intact.
- CESAcceptorCore.deferRepost already verifies valid index, idle state and non-stopping admission, matching the overlay intent.
- CESAcceptorCore.returnSlot already verifies index and legal ownership state. Retain posted OR transit withdrawals: current runtime calls it after a synchronous post refusal AND after a completed handoff is withdrawn; Zig AcceptorCore.returnSlot explicitly accepts these same two states (internal.zig:1123). The overlay's posted-only replacement would reject the legitimate transit withdrawal path, so that restriction is not applied. Existing pure transition tests cover both legitimate states and invalid states, and runtime verifies no provider ownership before return.

## Fault process scripts

Both overlay scripts cover the same previously missing mode groups and real cancellation peers. Current scripts retain that coverage and add stricter exact stage/native_error matching, stdout positive controls, actual-995-withheld evidence for both roles, all-thread Join markers, new source-fix modes, bounded async peer I/O and checked process cleanup. They use one fault-process suite each in the SwiftPM/PowerShell runner. Do not replace them with older glue that omits these assertions or uses synchronous unbounded connect/read operations.

The overlays' CMake/CTest packaging references and unresolved handoff note describe their historical snapshot. The user's latest SwiftPM-only decision and the now unified policy A supersede those instructions. Original incoming material will be archived under .superpowers before clearing it from the unrelated C++ repository.

This is static integration evidence; all actual compile/runtime gates remain pending.
