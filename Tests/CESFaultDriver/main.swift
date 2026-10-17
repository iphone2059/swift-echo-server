import CESServerCore
import Synchronization
// Test-only entry point. Every mode calls the production boundary; no fault mode
// is accepted by the server CLI and no production I/O path branches on a test flag.
import WinSDK

func makeWorker(
  rio: RIO_EXTENSION_FUNCTION_TABLE = RIO_EXTENSION_FUNCTION_TABLE(), index: UInt32 = 0,
  slots: UInt32 = 1, credits: UInt32 = 1
) throws(CESFailure) -> CESEngineWorker {
  var options = CESOptions()
  options.protocolKind = .tcp
  options.rioBufferBytes = 512
  options.cqCapacity = 64
  options.timeoutSeconds = 30
  options.workerCount = 1
  let configuration = CESWorkerConfiguration(
    options: options, rio: rio, control: CESSharedControl(), failure: CESFailureFlag(),
    credits: CESAdmissionCredits(capacity: credits), workerIndex: index, slotCount: slots,
    memoryShare: 1_048_576)
  return try CESEngineWorker(configuration: consume configuration)
}
/// Drives the production slot-ownership guards. Every case calls the engine the server runs, and a
/// case that expects a refusal terminates with the stage that engine produced, so the harness
/// observes the real boundary instead of a copy of it.
func slotScenario(_ mode: String) throws(CESFailure) {
  var worker = try makeWorker(slots: 2, credits: 2)
  withUnsafeMutablePointer(to: &worker) { w in
    func refuse(_ stage: String) -> Never {
      guard let failure = w.pointee.engine.failure,
        String(describing: failure.stage) == stage
      else { cesFailFast(stage: "slot guard did not fire", error: 13) }
      cesFailFast(stage: failure.stage, error: failure.code)
    }
    switch mode {
    case "slot_cycle_positive":
      guard let first = w.pointee.engine.takeSlot() else {
        cesFailFast(stage: "slot take", error: 13)
      }
      w.pointee.engine.returnSlot(first)
      guard let again = w.pointee.engine.takeSlot(), again == first else {
        cesFailFast(stage: "slot retake", error: 13)
      }
      w.pointee.engine.returnSlot(again)
      guard w.pointee.engine.failure == nil,
        w.pointee.engine.freeCount == w.pointee.configuration.slotCount
      else { cesFailFast(stage: "slot cycle state", error: 13) }
      print("slot cycle accepted")
    case "slot_return_duplicate":
      // Take both slots, give one back, then give the same one back again.
      guard let first = w.pointee.engine.takeSlot(), w.pointee.engine.takeSlot() != nil else {
        cesFailFast(stage: "slot take", error: 13)
      }
      w.pointee.engine.returnSlot(first)
      w.pointee.engine.returnSlot(first)
      refuse("TCP return slot ownership")
    case "slot_return_unowned":
      // A slot that was never taken cannot be given back, even with room in the pool.
      guard let taken = w.pointee.engine.takeSlot() else {
        cesFailFast(stage: "slot take", error: 13)
      }
      w.pointee.engine.returnSlot(taken == 0 ? 1 : 0)
      refuse("TCP return slot ownership")
    case "slot_return_active":
      guard let taken = w.pointee.engine.takeSlot() else {
        cesFailFast(stage: "slot take", error: 13)
      }
      guard w.pointee.engine.admit(index: taken, now: 0) != nil else {
        cesFailFast(stage: "slot admit", error: 13)
      }
      w.pointee.engine.returnSlot(taken)
      refuse("TCP return slot ownership")
    case "slot_admit_unreserved":
      guard let taken = w.pointee.engine.takeSlot() else {
        cesFailFast(stage: "slot take", error: 13)
      }
      w.pointee.engine.returnSlot(taken)
      _ = w.pointee.engine.admit(index: taken, now: 0)
      refuse("TCP admission state")
    default:
      cesFailFast(stage: "unknown slot mode", error: 13)
    }
    cesDestroyWorker(w)
  }
}

func completionScenario(_ mode: String) throws(CESFailure) {
  var worker = try makeWorker()
  withUnsafeMutablePointer(to: &worker) { w in
    guard let connections = CESPinnedStorage(count: 1, initialValue: CESEngineConnection()),
      let requests = CESPinnedStorage(count: 1, initialValue: CESEngineRequest())
    else { cesFailFast(stage: "fault allocation", error: 8) }
    w.pointee.connectionAddress = connections.baseAddress
    w.pointee.requestAddress = requests.baseAddress
    w.pointee.connections = consume connections
    w.pointee.requests = consume requests
    w.pointee.connectionAddress!.pointee.owner = w
    w.pointee.connectionAddress!.pointee.generation = 1
    w.pointee.connectionAddress!.pointee.providerOperation = .receive
    w.pointee.connectionAddress!.pointee.postedLength = 8
    w.pointee.providerOutstanding = 1
    guard
      let token = CESRequestContext.encode(
        index: 0, generation: 1, serial: 1, tag: CESRequestContext.receiveTag),
      let queueIdentity = CESRequestContext.encode(
        index: 0, generation: 1, serial: 0, tag: CESRequestContext.requestQueueTag)
    else { cesFailFast(stage: "fault context encode", error: 13) }
    w.pointee.requestAddress!.pointee.token = token
    var result = RIORESULT()
    result.RequestContext = token
    result.SocketContext = queueIdentity
    result.BytesTransferred = 4
    if mode == "completion_range" {
      // A context that names a slot this worker does not own.
      result.RequestContext =
        CESRequestContext.encode(
          index: 1, generation: 1, serial: 1, tag: CESRequestContext.receiveTag) ?? 0
    }
    if mode == "completion_forged" { result.RequestContext |= 1 << 47 }
    if mode == "completion_identity" { w.pointee.connectionAddress!.pointee.index = 1 }
    if mode == "completion_token" {
      result.RequestContext =
        CESRequestContext.encode(
          index: 0, generation: 1, serial: 2, tag: CESRequestContext.receiveTag) ?? 0
    }
    if mode == "completion_generation" {
      // The queue names the live generation while the posted token still names the retired one, so
      // the generation guard is the boundary that has to fire.
      w.pointee.connectionAddress!.pointee.generation = 2
      result.SocketContext =
        CESRequestContext.encode(
          index: 0, generation: 2, serial: 0, tag: CESRequestContext.requestQueueTag) ?? 0
    }
    if mode == "completion_socket_context" { result.SocketContext = 0 }
    if mode == "completion_length" { result.BytesTransferred = 9 }
    if mode == "completion_owner" { w.pointee.connectionAddress!.pointee.providerOperation = nil }
    let completion = cesWorkerNormalizeCompletion(w, result: result)
    guard
      completion.index == 0 && completion.bytes == 4 && completion.operation == .receive
        && w.pointee.providerOutstanding == 1
    else { cesFailFast(stage: "completion positive result", error: 13) }
    // The drain loop retires the lane together with the provider accounting; this scenario calls the
    // normalize boundary directly, so it retires both here.
    w.pointee.requestAddress!.pointee.token = 0
    w.pointee.connectionAddress!.pointee.providerOperation = nil
    w.pointee.providerOutstanding = 0
    cesDestroyWorker(w)
  }
  print("completion normalized")
}
func releaseScenario(_ mode: String) throws(CESFailure) {
  var worker = try makeWorker()
  withUnsafeMutablePointer(to: &worker) { w in
    if mode == "worker_release" {
      _ = w.pointee.engine.adoptNext(now: 0)
      cesDestroyWorker(w)
      return
    }
    if mode == "worker_release_order" {
      var record = CESEngineConnection()
      record.providerOperation = .receive
      withUnsafeMutablePointer(to: &record) { stack in
        w.pointee.connectionAddress = stack
        w.pointee.connections = CESPinnedStorage(unsafeAdoptingHeapAllocation: stack, count: 1)
        cesDestroyWorker(w)  // The named guard must precede HeapFree(stack).
      }
      return
    }
    guard let records = CESPinnedStorage(count: 1, initialValue: CESEngineConnection()),
      let lanes = CESPinnedStorage(count: 1, initialValue: CESEngineRequest())
    else {
      cesFailFast(stage: "fault allocation", error: 8)
    }
    w.pointee.connectionAddress = records.baseAddress
    w.pointee.connections = consume records
    w.pointee.requestAddress = lanes.baseAddress
    w.pointee.requests = consume lanes
    if mode == "slot_release" {
      w.pointee.connectionAddress!.pointee.providerOperation = .receive
      cesWorkerReleaseSlot(w, index: 0)
      return
    }
    if mode == "slot_release_positive" {
      guard w.pointee.configuration.credits.tryReserve() else {
        cesFailFast(stage: "credit positive reserve", error: 13)
      }
      cesWorkerReleaseSlot(w, index: 0)
      guard w.pointee.configuration.credits.isFull else {
        cesFailFast(stage: "credit positive release", error: 13)
      }
    }
    cesDestroyWorker(w)
  }
  print("worker released")
}
func acceptorReleaseScenario(order: Bool) throws(CESFailure) {
  var worker = try makeWorker()
  withUnsafeMutablePointer(to: &worker) { w in
    do {
      let configuration = CESAcceptorConfiguration(
        options: CESOptions(), control: CESSharedControl(), failure: CESFailureFlag(), workers: w,
        workerCount: 1)
      var acceptor = try CESEngineAcceptor(configuration: consume configuration)
      withUnsafeMutablePointer(to: &acceptor) { a in
        if order {
          var record = CESAcceptOperation()
          record.providerOwned = true
          withUnsafeMutablePointer(to: &record) { stack in
            // Only one slot is addressed by the guard before any storage can be freed.
            a.pointee.operationAddress = stack
            a.pointee.operations = CESPinnedStorage(unsafeAdoptingHeapAllocation: stack, count: 1)
            _ = a.pointee.core.markPosted(index: 0)
            cesDestroyAcceptor(a)
          }
        } else {
          cesDestroyAcceptor(a)
        }
      }
    } catch let error as CESFailure {
      cesFailFast(stage: error.stage, error: error.code)
    } catch { cesFailFast(stage: "fault unexpected acceptor setup error", error: 13) }
    cesDestroyWorker(w)
  }
  print("acceptor released")
}
func arenaScenario(_ mode: String) throws(CESFailure) {
  let winsock = try CESWinSockOwner()
  let rio = try cesLoadRIO()
  var arena = try CESRioArena(rio: rio, slots: 1, stride: 512, memoryLimit: 1_048_576)
  arena.didPost()
  if mode == "arena_release" {
    arena.release(providerOutstanding: 0, businessOutstanding: 0)
    return
  }
  if mode == "arena_deinit" { return }  // deinit must check its trusted ledger itself.
  arena.didComplete()
  arena.release(providerOutstanding: 0, businessOutstanding: 0)
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
  dequeueFault.withLock { state in
    state.original = rio
    state.enabled = drop
    state.dropped = false
    state.cancellationSeen = false
  }
  rio.RIODequeueCompletion = hideNativeCompletions
}
@c
func hideNativeCompletions(
  _ queue: RIO_CQ?, _ results: UnsafeMutablePointer<RIORESULT>?, _ capacity: UInt32
) -> UInt32 {
  // This mutex belongs only to the test adapter. Production still uses its native
  // static RIO table. Dequeue the real provider first and discard one observed
  // cancellation, so the CQ is actually drained and notifications do not spin.
  dequeueFault.withLock { state in
    let count = state.original.RIODequeueCompletion!(queue, results, capacity)
    if count == UInt32.max || count > capacity || count == 0 { return count }
    guard let results else { return count }
    var kept: UInt32 = 0
    for i in 0..<Int(count) {
      // Closing a socket aborts a pending RIO operation with ERROR_OPERATION_ABORTED
      // or, once the TCP connection is aborted as well, WSAECONNABORTED.
      if results[i].Status == 995 || results[i].Status == 10053 {
        state.cancellationSeen = true
      }
      if state.enabled && !state.dropped
        && (results[i].Status == 995 || results[i].Status == 10053)
      {
        state.dropped = true
        // cesReport writes directly to stderr before the production drain fails;
        // process termination cannot discard this evidence in a stdout buffer.
        cesReport(stage: "fault real cancellation completion withheld", error: 995)
        continue
      }
      results[Int(kept)] = results[i]
      kept += 1
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
    if let failure = cesInitializeWorker(w) {
      cesFailFast(stage: failure.stage, error: failure.code)
    }
    if let failure = cesStartWorker(w) { cesFailFast(stage: failure.stage, error: failure.code) }
    var options = CESOptions()
    options.protocolKind = .tcp
    options.port = 0
    let configuration = CESAcceptorConfiguration(
      options: options, control: CESSharedControl(), failure: w.pointee.configuration.failure,
      workers: w, workerCount: 1)
    do {
      var acceptor = try CESEngineAcceptor(configuration: consume configuration)
      withUnsafeMutablePointer(to: &acceptor) { a in
        w.pointee.acceptorAddress = a
        if let failure = cesInitializeAcceptor(a) {
          cesFailFast(stage: failure.stage, error: failure.code)
        }
        var bound = SOCKADDR_IN()
        var boundLength = Int32(MemoryLayout<SOCKADDR_IN>.size)
        let named = withUnsafeMutablePointer(to: &bound) {
          getsockname(
            a.pointee.listener.rawValue,
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: SOCKADDR.self), &boundLength)
        }
        if named != 0 { cesFailFast(stage: "fault getsockname", error: WSAGetLastError()) }
        if let failure = cesStartAcceptor(a) {
          cesFailFast(stage: failure.stage, error: failure.code)
        }
        var peer = CESSocketOwner(cesRegisteredSocket(transport: .tcp))
        guard peer.rawValue != ~SOCKET(0) else {
          cesFailFast(stage: "fault peer socket", error: WSAGetLastError())
        }
        var remote = SOCKADDR_IN()
        remote.sin_family = UInt16(AF_INET)
        remote.sin_port = bound.sin_port
        withUnsafeMutableBytes(of: &remote.sin_addr) { bytes in
          bytes[0] = 127
          bytes[1] = 0
          bytes[2] = 0
          bytes[3] = 1
        }
        let connected = withUnsafePointer(to: &remote) {
          connect(
            peer.rawValue, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self),
            Int32(MemoryLayout<SOCKADDR_IN>.size))
        }
        if connected != 0 { cesFailFast(stage: "fault peer connect", error: WSAGetLastError()) }
        let deadline = cesSaturatingAdd(GetTickCount64(), 10000)
        // This publication is atomic. Reading worker-private engine/transport state
        // before its Join would race the live worker and is deliberately avoided.
        while w.pointee.configuration.credits.isFull && GetTickCount64() < deadline { Sleep(1) }
        guard !w.pointee.configuration.credits.isFull else {
          cesFailFast(stage: "fault accept admission", error: 1460)
        }
        withUnsafeMutablePointer(to: &second) { other in
          if partial {
            if let failure = cesInitializeWorker(other) {
              cesFailFast(stage: failure.stage, error: failure.code)
            }
            // Storage exists, but the second thread is refused by the test seam.
            w.pointee.configuration.failure.failed.store(true, ordering: .releasing)
          }
          cesPostAcceptorStop(a)
          cesJoinAcceptor(a)
          // Acceptor Join includes acknowledgement of the first handoff; that
          // worker has genuinely submitted RIOReceive on a connected RIO socket.
          cesPostWorkerAdmissionClosed(w)
          cesPostWorkerStop(w)
          cesJoinWorker(w)
          cesJoinWorker(other)
          cesRequireAcceptorRelease(a)
          cesRequireWorkerRelease(w)
          cesRequireWorkerRelease(other)
          guard w.pointee.engine.statistics.completions >= 1 else {
            cesFailFast(stage: "fault receive was never submitted", error: 13)
          }
          cesDestroyAcceptor(a)
          cesDestroyWorker(w)
          cesDestroyWorker(other)
        }
        peer.reset()
      }
    } catch let error as CESFailure {
      cesFailFast(stage: error.stage, error: error.code)
    } catch { cesFailFast(stage: "fault unexpected acceptor setup error", error: 13) }
  }
  winsock.keepAlive()
  print(partial ? "partial startup drained workers=1" : "native worker drained")
}
func coordinatorIOScenario(port: UInt16, missing: Bool) throws(CESFailure) -> CESExitCode {
  let winsock = try CESWinSockOwner()
  var rio = try cesLoadRIO()
  configureDequeue(&rio, drop: missing)
  var options = CESOptions()
  options.protocolKind = .tcp
  options.port = port
  options.workerCount = 1
  options.cqCapacity = 64
  options.runSeconds = 1
  options.timeoutSeconds = 1
  options.memoryBytes = 1_048_576
  let result = cesRunTCPServer(rio: rio, options: options, control: CESSharedControl())
  // If no real 995 completion was observed, the negative case must not masquerade
  // as a successful missing-completion regression.
  if missing { cesFailFast(stage: "fault cancellation was not dropped", error: 13) }
  if !dequeueFault.withLock({ $0.cancellationSeen }) {
    cesFailFast(stage: "fault receive was never canceled", error: 13)
  }
  winsock.keepAlive()
  print("e2e cancellation drained")
  return result
}
func run() -> UInt32 {
  let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "normal"
  do {
    switch mode {
    case "normal":
      cesRequireRIONotifySuccess(0, stage: "normal")
      _ = cesRequireValidDequeueCount(0, stage: "normal")
      cesRequireOutstanding(1, stage: "normal")
      cesRequireControlPostSuccess(true, error: 0, stage: "normal")
      print("normal guards accepted")
    case "notify_failure": cesRequireRIONotifySuccess(5, stage: "fault notify")
    case "notify_duplicate": cesRequireRIONotifySuccess(10037, stage: "fault notify")
    case "corrupt_cq": _ = cesRequireValidDequeueCount(UInt32.max, stage: "fault CQ")
    case "outstanding_underflow": cesRequireOutstanding(0, stage: "fault outstanding")
    case "control_post_failure":
      cesRequireControlPostSuccess(false, error: 5, stage: "fault control post")
    case "accept_completion_positive":
      cesRequireAcceptCompletionExtent(0)
      print("accept completion extent accepted")
    case "accept_completion_length": cesRequireAcceptCompletionExtent(1)
    case "handoff_positive":
      cesRequireAcceptHandoffSocket(true)
      print("accept handoff socket accepted")
    case "handoff_invalid_socket": cesRequireAcceptHandoffSocket(false)
    case "completion_positive", "completion_range", "completion_forged", "completion_identity",
      "completion_token", "completion_generation", "completion_socket_context", "completion_length",
      "completion_owner":
      try completionScenario(mode)
    case "slot_cycle_positive", "slot_return_duplicate", "slot_return_unowned",
      "slot_return_active",
      "slot_admit_unreserved":
      try slotScenario(mode)
    case "worker_release", "worker_release_order", "worker_release_positive", "slot_release",
      "slot_release_positive":
      try releaseScenario(mode)
    case "acceptor_release_order": try acceptorReleaseScenario(order: true)
    case "acceptor_release_positive": try acceptorReleaseScenario(order: false)
    case "arena_release", "arena_deinit", "arena_release_positive": try arenaScenario(mode)
    case "worker_missing_completion": try nativeIOScenario(missing: true, partial: false)
    case "worker_cancel_positive": try nativeIOScenario(missing: false, partial: false)
    case "partial_startup":
      try nativeIOScenario(missing: false, partial: true)
      return 2
    case "e2e_missing_completion", "e2e_cancel_positive":
      guard CommandLine.arguments.count > 2, let port = UInt16(CommandLine.arguments[2]), port != 0
      else { return 1 }
      return UInt32(
        try coordinatorIOScenario(port: port, missing: mode == "e2e_missing_completion").rawValue)
    default: return 1
    }
    return 0
  } catch {
    cesReport(stage: error.stage, error: error.code)
    return 2
  }
}
ExitProcess(run())
