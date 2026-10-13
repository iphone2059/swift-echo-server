import CESServerCore
import Synchronization
import WinSDK

// Test-only entry point. Every mode calls the production boundary; no fault mode
// is accepted by the server CLI and no production I/O path branches on a test flag.
func makeWorker(rio: RIO_EXTENSION_FUNCTION_TABLE = RIO_EXTENSION_FUNCTION_TABLE(), index: UInt32 = 0) throws(CESFailure) -> CESEngineWorker {
  var options = CESOptions()
  options.protocolKind = .tcp; options.rioBufferBytes = 512
  options.cqCapacity = 64; options.timeoutSeconds = 30; options.workerCount = 1
  let configuration = CESWorkerConfiguration(options: options, rio: rio, control: CESSharedControl(), failure: CESFailureFlag(), credits: CESAdmissionCredits(capacity: 1), workerIndex: index, slotCount: 1, memoryShare: 1048576)
  return try CESEngineWorker(configuration: consume configuration)
}
func completionScenario(_ mode: String) throws(CESFailure) {
  var worker = try makeWorker()
  withUnsafeMutablePointer(to: &worker) { w in
    guard let connections = CESPinnedStorage(count: 1, initialValue: CESEngineConnection()), let requests = CESPinnedStorage(count: 1, initialValue: CESEngineRequest()) else { cesFailFast(stage: "fault allocation", error: 8) }
    w.pointee.connectionAddress = connections.baseAddress; w.pointee.requestAddress = requests.baseAddress
    w.pointee.connections = consume connections; w.pointee.requests = consume requests
    let first = UInt(bitPattern: w.pointee.requestAddress!)
    w.pointee.requestRange = first..<(first + UInt(MemoryLayout<CESEngineRequest>.stride))
    w.pointee.connectionAddress!.pointee.owner = w
    w.pointee.connectionAddress!.pointee.providerOperation = .receive
    w.pointee.connectionAddress!.pointee.postedLength = 8
    w.pointee.providerOutstanding = 1
    var result = RIORESULT(); result.RequestContext = UInt64(first); result.BytesTransferred = 4
    if mode == "completion_range" { result.RequestContext = UInt64(w.pointee.requestRange.upperBound) }
    if mode == "completion_alignment" { result.RequestContext += 1 }
    if mode == "completion_identity" { w.pointee.connectionAddress!.pointee.index = 1 }
    if mode == "completion_length" { result.BytesTransferred = 9 }
    if mode == "completion_owner" { w.pointee.connectionAddress!.pointee.providerOperation = nil }
    let completion = cesWorkerNormalizeCompletion(w, result: result)
    guard completion.index == 0 && completion.bytes == 4 && completion.operation == .receive && w.pointee.providerOutstanding == 1 else { cesFailFast(stage: "completion positive result", error: 13) }
    w.pointee.connectionAddress!.pointee.providerOperation = nil; w.pointee.providerOutstanding = 0
    cesDestroyWorker(w)
  }
  print("completion normalized")
}
func releaseScenario(_ mode: String) throws(CESFailure) {
  var worker = try makeWorker()
  withUnsafeMutablePointer(to: &worker) { w in
    if mode == "worker_release" { _ = w.pointee.engine.adoptNext(now: 0); cesDestroyWorker(w); return }
    if mode == "worker_release_order" {
      var record = CESEngineConnection(); record.providerOperation = .receive
      withUnsafeMutablePointer(to: &record) { stack in
        w.pointee.connectionAddress = stack
        w.pointee.connections = CESPinnedStorage(unsafeAdoptingHeapAllocation: stack, count: 1)
        cesDestroyWorker(w) // The named guard must precede HeapFree(stack).
      }
      return
    }
    guard let records = CESPinnedStorage(count: 1, initialValue: CESEngineConnection()) else { cesFailFast(stage: "fault allocation", error: 8) }
    w.pointee.connectionAddress = records.baseAddress; w.pointee.connections = consume records
    if mode == "slot_release" { w.pointee.connectionAddress!.pointee.providerOperation = .receive; cesWorkerReleaseSlot(w, index: 0); return }
    if mode == "slot_release_positive" {
      guard w.pointee.configuration.credits.tryReserve() else { cesFailFast(stage: "credit positive reserve", error: 13) }
      cesWorkerReleaseSlot(w, index: 0)
      guard w.pointee.configuration.credits.isFull else { cesFailFast(stage: "credit positive release", error: 13) }
    }
    cesDestroyWorker(w)
  }
  print("worker released")
}
func acceptorReleaseScenario(order: Bool) throws(CESFailure) {
  var worker = try makeWorker()
  withUnsafeMutablePointer(to: &worker) { w in
    do {
      let configuration = CESAcceptorConfiguration(options: CESOptions(), control: CESSharedControl(), failure: CESFailureFlag(), workers: w, workerCount: 1)
      var acceptor = try CESEngineAcceptor(configuration: consume configuration)
      withUnsafeMutablePointer(to: &acceptor) { a in
        if order {
          var record = CESAcceptOperation(); record.providerOwned = true
          withUnsafeMutablePointer(to: &record) { stack in
            // Only one slot is addressed by the guard before any storage can be freed.
            a.pointee.operationAddress = stack
            a.pointee.operations = CESPinnedStorage(unsafeAdoptingHeapAllocation: stack, count: 1)
            _ = a.pointee.core.markPosted(index: 0)
            cesDestroyAcceptor(a)
          }
        } else { cesDestroyAcceptor(a) }
      }
    } catch { cesFailFast(stage: error.stage, error: error.code) }
    cesDestroyWorker(w)
  }
  print("acceptor released")
}
func arenaScenario(_ mode: String) throws(CESFailure) {
  let winsock = try CESWinSockOwner()
  let rio = try cesLoadRIO()
  var arena = try CESRioArena(rio: rio, slots: 1, stride: 512, memoryLimit: 1048576)
  arena.didPost()
  if mode == "arena_release" { arena.release(providerOutstanding: 0, businessOutstanding: 0); return }
  if mode == "arena_deinit" { return } // deinit must check its trusted ledger itself.
  arena.didComplete(); arena.release(providerOutstanding: 0, businessOutstanding: 0)
  winsock.keepAlive()
  print("arena released")
}
private struct DequeueFaultState {
  var original = RIO_EXTENSION_FUNCTION_TABLE()
  var enabled = false
  var dropped = false
  var cancellationSeen = false
}
private let dequeueFault = Mutex(DequeueFaultState())
func configureDequeue(_ rio: inout RIO_EXTENSION_FUNCTION_TABLE, drop: Bool) {
  dequeueFault.withLock { state in state.original = rio; state.enabled = drop; state.dropped = false; state.cancellationSeen = false }
  rio.RIODequeueCompletion = hideNativeCompletions
}
@c
func hideNativeCompletions(_ queue: RIO_CQ?, _ results: UnsafeMutablePointer<RIORESULT>?, _ capacity: UInt32) -> UInt32 {
  // This mutex belongs only to the test adapter. Production still uses its native
  // static RIO table. Dequeue the real provider first and discard one observed
  // cancellation, so the CQ is actually drained and notifications do not spin.
  dequeueFault.withLock { state in
    let count = state.original.RIODequeueCompletion!(queue, results, capacity)
    if count == UInt32.max || count > capacity || count == 0 { return count }
    guard let results else { return count }
    var kept: UInt32 = 0
    for i in 0..<Int(count) {
      if results[i].Status == 995 { state.cancellationSeen = true }
      if state.enabled && !state.dropped && results[i].Status == 995 { state.dropped = true; continue }
      results[Int(kept)] = results[i]; kept += 1
    }
    return kept
  }
}
func nativeIOScenario(missing: Bool, partial: Bool) throws(CESFailure) {
  let winsock = try CESWinSockOwner()
  var rio = try cesLoadRIO()
  configureDequeue(&rio, drop: missing)
  var first = try makeWorker(rio: rio)
  var second = try makeWorker(rio: rio, index: 1)
  withUnsafeMutablePointer(to: &first) { w in
    if let failure = cesInitializeWorker(w) { cesFailFast(stage: failure.stage, error: failure.code) }
    if let failure = cesStartWorker(w) { cesFailFast(stage: failure.stage, error: failure.code) }
    var options = CESOptions(); options.protocolKind = .tcp; options.port = 0
    let configuration = CESAcceptorConfiguration(options: options, control: CESSharedControl(), failure: w.pointee.configuration.failure, workers: w, workerCount: 1)
    do {
      var acceptor = try CESEngineAcceptor(configuration: consume configuration)
      withUnsafeMutablePointer(to: &acceptor) { a in
        w.pointee.acceptorAddress = a
        if let failure = cesInitializeAcceptor(a) { cesFailFast(stage: failure.stage, error: failure.code) }
        var bound = SOCKADDR_IN(); var boundLength = Int32(MemoryLayout<SOCKADDR_IN>.size)
        let named = withUnsafeMutablePointer(to: &bound) { getsockname(a.pointee.listener.rawValue, UnsafeMutableRawPointer($0).assumingMemoryBound(to: SOCKADDR.self), &boundLength) }
        if named != 0 { cesFailFast(stage: "fault getsockname", error: WSAGetLastError()) }
        if let failure = cesStartAcceptor(a) { cesFailFast(stage: failure.stage, error: failure.code) }
        var peer = CESSocketOwner(cesRegisteredSocket(transport: .tcp))
        guard peer.rawValue != ~SOCKET(0) else { cesFailFast(stage: "fault peer socket", error: WSAGetLastError()) }
        var remote = SOCKADDR_IN(); remote.sin_family = UInt16(AF_INET)
        remote.sin_port = bound.sin_port
        withUnsafeMutableBytes(of: &remote.sin_addr) { bytes in bytes[0] = 127; bytes[1] = 0; bytes[2] = 0; bytes[3] = 1 }
        let connected = withUnsafePointer(to: &remote) { connect(peer.rawValue, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self), Int32(MemoryLayout<SOCKADDR_IN>.size)) }
        if connected != 0 { cesFailFast(stage: "fault peer connect", error: WSAGetLastError()) }
        let deadline = cesSaturatingAdd(GetTickCount64(), 10000)
        // This publication is atomic. Reading worker-private engine/transport state
        // before its Join would race the live worker and is deliberately avoided.
        while w.pointee.configuration.credits.isFull && GetTickCount64() < deadline { Sleep(1) }
        guard !w.pointee.configuration.credits.isFull else { cesFailFast(stage: "fault accept admission", error: 1460) }
        withUnsafeMutablePointer(to: &second) { other in
          if partial {
            if let failure = cesInitializeWorker(other) { cesFailFast(stage: failure.stage, error: failure.code) }
            // Storage exists, but the second thread is refused by the test seam.
            w.pointee.configuration.failure.failed.store(true, ordering: .releasing)
          }
          cesPostAcceptorStop(a); cesJoinAcceptor(a)
          // Acceptor Join includes acknowledgement of the first handoff; that
          // worker has genuinely submitted RIOReceive on a connected RIO socket.
          cesPostWorkerAdmissionClosed(w); cesPostWorkerStop(w)
          cesJoinWorker(w); cesJoinWorker(other)
          cesRequireAcceptorRelease(a); cesRequireWorkerRelease(w); cesRequireWorkerRelease(other)
          guard w.pointee.engine.statistics.completions >= 1 else { cesFailFast(stage: "fault receive was never submitted", error: 13) }
          cesDestroyAcceptor(a); cesDestroyWorker(w); cesDestroyWorker(other)
        }
        peer.reset()
      }
    } catch { cesFailFast(stage: error.stage, error: error.code) }
  }
  winsock.keepAlive()
  print(partial ? "partial startup drained workers=1" : "native worker drained")
}
func coordinatorIOScenario(port: UInt16, missing: Bool) throws(CESFailure) -> CESExitCode {
  let winsock = try CESWinSockOwner()
  var rio = try cesLoadRIO()
  configureDequeue(&rio, drop: missing)
  var options = CESOptions()
  options.protocolKind = .tcp; options.port = port; options.workerCount = 1
  options.cqCapacity = 64; options.runSeconds = 1; options.timeoutSeconds = 1
  options.memoryBytes = 1048576
  let result = cesRunTCPServer(rio: rio, options: options, control: CESSharedControl())
  // If no real 995 completion was observed, the negative case must not masquerade
  // as a successful missing-completion regression.
  if missing { cesFailFast(stage: "fault cancellation was not dropped", error: 13) }
  if !dequeueFault.withLock({ $0.cancellationSeen }) { cesFailFast(stage: "fault receive was never canceled", error: 13) }
  winsock.keepAlive()
  print("e2e cancellation drained")
  return result
}
func run() -> UInt32 {
  let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "normal"
  do {
    switch mode {
    case "normal":
      cesRequireRIONotifySuccess(0, stage: "normal"); _ = cesRequireValidDequeueCount(0, stage: "normal")
      cesRequireOutstanding(1, stage: "normal"); cesRequireControlPostSuccess(true, error: 0, stage: "normal")
      print("normal guards accepted")
    case "notify_failure": cesRequireRIONotifySuccess(5, stage: "fault notify")
    case "notify_duplicate": cesRequireRIONotifySuccess(10037, stage: "fault notify")
    case "corrupt_cq": _ = cesRequireValidDequeueCount(UInt32.max, stage: "fault CQ")
    case "outstanding_underflow": cesRequireOutstanding(0, stage: "fault outstanding")
    case "control_post_failure": cesRequireControlPostSuccess(false, error: 5, stage: "fault control post")
    case "completion_positive", "completion_range", "completion_alignment", "completion_identity", "completion_length", "completion_owner": try completionScenario(mode)
    case "worker_release", "worker_release_order", "worker_release_positive", "slot_release", "slot_release_positive": try releaseScenario(mode)
    case "acceptor_release_order": try acceptorReleaseScenario(order: true)
    case "acceptor_release_positive": try acceptorReleaseScenario(order: false)
    case "arena_release", "arena_deinit", "arena_release_positive": try arenaScenario(mode)
    case "worker_missing_completion": try nativeIOScenario(missing: true, partial: false)
    case "worker_cancel_positive": try nativeIOScenario(missing: false, partial: false)
    case "partial_startup": try nativeIOScenario(missing: false, partial: true); return 2
    case "e2e_missing_completion", "e2e_cancel_positive":
      guard CommandLine.arguments.count > 2, let port = UInt16(CommandLine.arguments[2]), port != 0 else { return 1 }
      return UInt32(try coordinatorIOScenario(port: port, missing: mode == "e2e_missing_completion").rawValue)
    default: return 1
    }
    return 0
  } catch { cesReport(stage: error.stage, error: error.code); return 2 }
}
ExitProcess(run())
