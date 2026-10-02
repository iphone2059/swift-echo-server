import WinSDK

// Native boundary invariants:
// - w and c point into pinned worker/connection owners, retained until join.
// - Only the native worker mutates connection state, timers and outstanding counts.
// - RIO retains request contexts and buffers until the matching completion; closing
//   the socket cancels requests, and draining completes before allocation release.
// - Incoming completion addresses are range/identity checked before dereference.
// - The echo path never copies payload bytes: RIO moves them from the arena to the
//   socket and back through the same registered region.

private func connections(_ w: UnsafeMutablePointer<CESEngineWorker>) -> UnsafeMutablePointer<
  CESEngineConnection
> { unsafe w.pointee.connectionAddress! }
private func requests(_ w: UnsafeMutablePointer<CESEngineWorker>) -> UnsafeMutablePointer<
  CESEngineRequest
> { unsafe w.pointee.requestAddress! }
private func registration(_ w: UnsafeMutablePointer<CESEngineWorker>) -> RIO_BUFFERID {
  unsafe w.pointee.resources.registration.rawValue!
}
private func connectionSocketClose(_ c: UnsafeMutablePointer<CESEngineConnection>) {
  unsafe c.pointee.owner!.pointee.resources.sockets[Int(c.pointee.index)].reset()
  unsafe c.pointee.socket = ~SOCKET(0)
}
private func schedule(_ c: UnsafeMutablePointer<CESEngineConnection>, _ deadline: UInt64) {
  if unsafe !c.pointee.owner!.pointee.timers.insertOrUpdate(
    connectionIndex: c.pointee.index, deadline: deadline)
  {
    cesFailFast(stage: "server timer insert/update", error: 13)
  }
}
private func releaseConnection(_ c: UnsafeMutablePointer<CESEngineConnection>) {
  let w = unsafe c.pointee.owner!
  unsafe connectionSocketClose(c)
  unsafe c.pointee.requestQueue = nil
  unsafe c.pointee.active = false
  unsafe c.pointee.closing = false
  unsafe c.pointee.outstanding = 0
  unsafe w.pointee.freeIndices[Int(w.pointee.freeCount)] = c.pointee.index
  unsafe w.pointee.freeCount += 1
  unsafe w.pointee.activeCount -= 1
}
private func closeConnection(_ c: UnsafeMutablePointer<CESEngineConnection>) {
  if unsafe !c.pointee.active || c.pointee.closing { return }
  unsafe c.pointee.closing = true
  _ = unsafe c.pointee.owner!.pointee.timers.remove(connectionIndex: c.pointee.index)
  unsafe connectionSocketClose(c)
  if unsafe c.pointee.outstanding == 0 { unsafe releaseConnection(c) }
}
private func refreshDeadline(_ c: UnsafeMutablePointer<CESEngineConnection>, seconds: UInt32) {
  unsafe c.pointee.deadline = GetTickCount64() + UInt64(seconds) * 1000
  unsafe schedule(c, c.pointee.deadline)
}
// SE-0537: kept together with the rest of the RIO completion path in one COFF
// section so the linker can lay the hot loop out as a unit.
@section(".text$CESRIO")
private func postReceive(
  _ c: UnsafeMutablePointer<CESEngineConnection>, configuration: borrowing CESWorkerConfiguration
) -> Bool {
  let w = unsafe c.pointee.owner!
  unsafe requests(w)[Int(c.pointee.index)].operation = .receive
  unsafe cesConnectionBuffer(c).pointee.Length = unsafe w.pointee.stride
  guard
    unsafe configuration.rio.RIOReceive!(
      c.pointee.requestQueue, cesConnectionBuffer(c), 1, 0,
      unsafe requests(w).advanced(by: Int(c.pointee.index)))
      .boolValue
  else {
    cesReport(stage: "RIOReceive", error: WSAGetLastError())
    return false
  }
  unsafe c.pointee.outstanding += 1
  unsafe refreshDeadline(c, seconds: configuration.options.timeoutSeconds)
  return true
}
// SE-0537: kept together with the rest of the RIO completion path in one COFF
// section so the linker can lay the hot loop out as a unit.
@section(".text$CESRIO")
private func postSend(
  _ c: UnsafeMutablePointer<CESEngineConnection>, configuration: borrowing CESWorkerConfiguration
) -> Bool {
  let w = unsafe c.pointee.owner!
  guard unsafe c.pointee.sendOffset >= 0, unsafe c.pointee.sendOffset < c.pointee.echoBytes,
    unsafe c.pointee.echoBytes <= Int(w.pointee.stride)
  else { cesFailFast(stage: "server send registration extent", error: 13) }
  unsafe requests(w)[Int(c.pointee.index)].operation = .send
  let buffer = unsafe cesConnectionBuffer(c)
  unsafe buffer.pointee.Offset = UInt32(
    UInt64(c.pointee.index) * UInt64(w.pointee.stride) + UInt64(c.pointee.sendOffset))
  unsafe buffer.pointee.Length = UInt32(unsafe c.pointee.echoBytes - c.pointee.sendOffset)
  guard
    unsafe configuration.rio.RIOSend!(
      c.pointee.requestQueue, buffer, 1, 0,
      unsafe requests(w).advanced(by: Int(c.pointee.index)))
      .boolValue
  else {
    cesReport(stage: "RIOSend", error: WSAGetLastError())
    return false
  }
  unsafe c.pointee.outstanding += 1
  unsafe refreshDeadline(c, seconds: configuration.options.timeoutSeconds)
  return true
}
// SE-0537: kept together with the rest of the RIO completion path in one COFF
// section so the linker can lay the hot loop out as a unit.
@section(".text$CESRIO")
private func processResult(
  _ w: UnsafeMutablePointer<CESEngineWorker>, result: RIORESULT,
  configuration: borrowing CESWorkerConfiguration
) {
  unsafe w.pointee.completionCount += 1
  let first = unsafe UInt(bitPattern: requests(w))
  let stride = unsafe UInt(MemoryLayout<CESEngineRequest>.stride)
  let requestAddress = UInt(result.RequestContext)
  // Check allocation range, alignment and field identity before dereferencing
  // the native request context.
  guard stride != 0, unsafe w.pointee.requestRange.contains(requestAddress) else {
    cesFailFast(stage: "server RIO RequestContext range", error: 13)
  }
  let offset = requestAddress - first
  guard offset % stride == 0 else {
    cesFailFast(stage: "server RIO RequestContext alignment", error: 13)
  }
  let index = offset / stride
  let c = unsafe connections(w).advanced(by: Int(index))
  let request = unsafe requests(w).advanced(by: Int(index))
  guard unsafe request.pointee.connectionIndex == UInt32(index),
    unsafe c.pointee.owner == w, unsafe c.pointee.index == UInt32(index)
  else { cesFailFast(stage: "server RIO request metadata", error: 13) }
  let operation = unsafe request.pointee.operation
  unsafe cesRequireOutstanding(c.pointee.outstanding, stage: "server RIO outstanding count")
  unsafe c.pointee.outstanding -= 1
  if unsafe c.pointee.closing {
    if unsafe c.pointee.outstanding == 0 { unsafe releaseConnection(c) }
    return
  }
  if result.Status != 0 {
    unsafe closeConnection(c)
    return
  }
  if operation == .receive {
    unsafe w.pointee.receiveCount += 1
    if result.BytesTransferred == 0 {
      unsafe closeConnection(c)
      return
    }
    unsafe c.pointee.echoBytes = Int(result.BytesTransferred)
    unsafe c.pointee.sendOffset = 0
    if unsafe !postSend(c, configuration: configuration) { unsafe closeConnection(c) }
    return
  }
  unsafe w.pointee.sendCount += 1
  unsafe w.pointee.echoedBytes &+= UInt64(result.BytesTransferred)
  guard
    unsafe cesAdvanceOffset(
      total: c.pointee.echoBytes, transferred: Int(result.BytesTransferred),
      offset: &c.pointee.sendOffset)
  else {
    unsafe closeConnection(c)
    return
  }
  if unsafe c.pointee.sendOffset < c.pointee.echoBytes {
    if unsafe !postSend(c, configuration: configuration) { unsafe closeConnection(c) }
    return
  }
  let buffer = unsafe cesConnectionBuffer(c)
  unsafe buffer.pointee.Offset = UInt32(UInt64(c.pointee.index) * UInt64(w.pointee.stride))
  if unsafe !postReceive(c, configuration: configuration) { unsafe closeConnection(c) }
}
private func arm(
  _ w: UnsafeMutablePointer<CESEngineWorker>, configuration: borrowing CESWorkerConfiguration
) {
  guard unsafe !w.pointee.notificationArmed else {
    cesFailFast(stage: "server duplicate worker RIONotify", error: 5023)
  }
  let notification = unsafe w.pointee.notificationAddress!
  unsafe notification.pointee = OVERLAPPED()
  cesRequireRIONotifySuccess(
    unsafe configuration.rio.RIONotify!(w.pointee.resources.completionQueue.rawValue),
    stage: "RIONotify(worker)")
  if unsafe !cesNotificationMarkRearmed(&w.pointee.notificationArmed) {
    cesFailFast(stage: "server worker notification rearm transition", error: 5023)
  }
}
// SE-0537: kept together with the rest of the RIO completion path in one COFF
// section so the linker can lay the hot loop out as a unit.
@section(".text$CESRIO")
private func drainCompletions(
  _ w: UnsafeMutablePointer<CESEngineWorker>, configuration: borrowing CESWorkerConfiguration
) {
  let results = unsafe w.pointee.resultsAddress!
  // A saturated echo peer can keep the queue non-empty indefinitely, so the drain
  // yields to the control path after a bounded number of batches. Pending results
  // stay in the CQ and the notification is re-armed by the caller.
  for _ in 0..<64 {
    let count = unsafe cesRequireValidDequeueCount(
      configuration.rio.RIODequeueCompletion!(
        unsafe w.pointee.resources.completionQueue.rawValue, results,
        UInt32(CESConstants.completionBatchSize)),
      stage: "RIODequeueCompletion(worker)")
    if count == 0 { return }
    guard Int(count) <= CESConstants.completionBatchSize else {
      cesFailFast(stage: "server dequeue batch", error: 13)
    }
    for i in 0..<Int(count) {
      unsafe processResult(w, result: results[i], configuration: configuration)
    }
    if unsafe configuration.control.stopRequested.load(ordering: .acquiring) { return }
  }
}
private func processDeadlines(
  _ w: UnsafeMutablePointer<CESEngineWorker>, configuration: borrowing CESWorkerConfiguration
) {
  let now = GetTickCount64()
  while let index = unsafe w.pointee.timers.popExpired(now: now) {
    let c = unsafe connections(w).advanced(by: Int(index))
    if unsafe c.pointee.active && !c.pointee.closing { unsafe closeConnection(c) }
  }
}
private func stopWorker(_ w: UnsafeMutablePointer<CESEngineWorker>) {
  if unsafe w.pointee.stopping { return }
  unsafe w.pointee.stopping = true
  unsafe w.pointee.phase = .draining
  for index in unsafe 0..<w.pointee.slotCount {
    let c = unsafe connections(w).advanced(by: Int(index))
    if unsafe c.pointee.active { unsafe closeConnection(c) }
  }
}
private func takeSocket(
  _ w: UnsafeMutablePointer<CESEngineWorker>, operation: UnsafeMutablePointer<CESAcceptOperation>,
  configuration: borrowing CESWorkerConfiguration
) {
  // The acceptor transferred the accepted socket into the operation record before it
  // posted the handoff, so this thread never reaches into the acceptor's owners.
  let accepted = unsafe operation.pointee.socket
  guard accepted != ~SOCKET(0) else {
    cesFailFast(stage: "server accept handoff socket", error: 13)
  }
  unsafe operation.pointee.socket = ~SOCKET(0)
  var acceptedOwner = CESSocketOwner(accepted)
  if unsafe w.pointee.stopping || w.pointee.freeCount == 0 {
    unsafe cesAckAccept(operation)
    return
  }
  let index = unsafe w.pointee.freeIndices[Int(w.pointee.freeCount - 1)]
  unsafe w.pointee.freeCount -= 1
  let c = unsafe connections(w).advanced(by: Int(index))
  unsafe c.pointee.owner = w
  unsafe w.pointee.resources.sockets[Int(index)].reset(acceptedOwner.release())
  unsafe c.pointee.socket = accepted
  unsafe c.pointee.index = index
  unsafe c.pointee.active = true
  unsafe c.pointee.closing = false
  unsafe c.pointee.outstanding = 0
  unsafe c.pointee.echoBytes = 0
  unsafe c.pointee.sendOffset = 0
  unsafe requests(w)[Int(index)].connectionIndex = index
  unsafe requests(w)[Int(index)].operation = .receive
  let buffer = unsafe cesConnectionBuffer(c)
  unsafe buffer.pointee.BufferId = registration(w)
  unsafe buffer.pointee.Offset = UInt32(UInt64(index) * UInt64(w.pointee.stride))
  unsafe buffer.pointee.Length = unsafe w.pointee.stride
  // The peer address was already validated by the acceptor through
  // GetAcceptExSockaddrs; no second query is needed on this hot path.
  guard
    let requestQueue = unsafe configuration.rio.RIOCreateRequestQueue!(
      accepted, 1, 1, 1, 1, w.pointee.resources.completionQueue.rawValue,
      w.pointee.resources.completionQueue.rawValue, UnsafeMutableRawPointer(c))
  else {
    cesReport(stage: "RIOCreateRequestQueue(TCP)", error: WSAGetLastError())
    unsafe c.pointee.active = false
    unsafe w.pointee.freeIndices[Int(w.pointee.freeCount)] = index
    unsafe w.pointee.freeCount += 1
    unsafe connectionSocketClose(c)
    unsafe cesAckAccept(operation)
    return
  }
  unsafe c.pointee.requestQueue = requestQueue
  unsafe w.pointee.activeCount += 1
  unsafe w.pointee.acceptedCount += 1
  if unsafe !postReceive(c, configuration: configuration) { unsafe closeConnection(c) }
  unsafe cesAckAccept(operation)
}
private func runWorker(
  _ w: UnsafeMutablePointer<CESEngineWorker>, configuration: borrowing CESWorkerConfiguration
) -> DWORD {
  unsafe w.pointee.phase = .running
  unsafe w.pointee.ready = true
  if unsafe SetEvent(w.pointee.resources.readyEvent.rawValue) == false {
    cesFailFast(stage: "SetEvent(worker ready)", error: Int32(bitPattern: GetLastError()))
  }
  while true {
    // Lazy notification: a registration exists only while this worker owns connections
    // with requests in flight, so an idle worker never holds a pending RIONotify and
    // nothing has to be released before the completion queue is destroyed. RIONotify
    // called with a non-empty queue notifies immediately, so a completion arriving
    // between the post and this arm cannot be lost.
    if unsafe w.pointee.activeCount != 0 && !w.pointee.notificationArmed {
      unsafe arm(w, configuration: configuration)
    }
    var transferred: DWORD = 0
    var key: UInt64 = 0
    var overlap: UnsafeMutablePointer<OVERLAPPED>?
    let now = GetTickCount64()
    let ok = unsafe GetQueuedCompletionStatus(
      w.pointee.resources.port.rawValue, &transferred, &key, &overlap,
      unsafe w.pointee.timers.waitMilliseconds(now: now))
    let error = ok ? 0 : GetLastError()
    let notification = unsafe w.pointee.notificationAddress!
    if unsafe overlap == notification {
      if !ok {
        cesFailFast(
          stage: "GetQueuedCompletionStatus(worker notification)",
          error: Int32(bitPattern: error))
      }
      unsafe cesRequireNotificationPacket(
        key: UInt(key), overlapped: overlap, expectedKey: UInt(bitPattern: w),
        expectedOverlapped: notification, stage: "server worker RIO notification key")
      if unsafe !cesNotificationMarkDelivered(&w.pointee.notificationArmed) {
        cesFailFast(stage: "server worker notification delivery transition", error: 5023)
      }
      unsafe drainCompletions(w, configuration: configuration)
    } else if unsafe overlap == nil && key == CESConstants.stopKey {
      unsafe stopWorker(w)
    } else if unsafe overlap == nil && key == CESConstants.admissionClosedKey {
      unsafe w.pointee.admissionClosed = true
    } else if unsafe overlap == nil && key > CESConstants.admissionClosedKey {
      let candidate = UInt(key)
      let acceptor = unsafe w.pointee.acceptorAddress
      guard let acceptor = unsafe acceptor else {
        cesFailFast(stage: "server accept handoff without acceptor", error: 13)
      }
      guard let operation = unsafe cesAcceptorOperationForAddress(acceptor, address: candidate) else {
        cesFailFast(stage: "server accept handoff identity", error: 13)
      }
      unsafe takeSocket(w, operation: operation, configuration: configuration)
    } else if !ok && error != WAIT_TIMEOUT {
      cesReport(stage: "GetQueuedCompletionStatus(worker)", error: Int32(bitPattern: error))
      unsafe configuration.failure.failed.store(true, ordering: .releasing)
      unsafe stopWorker(w)
    } else if unsafe !(!ok && error == WAIT_TIMEOUT && overlap == nil) {
      cesFailFast(stage: "unexpected worker IOCP packet", error: 13)
    }
    unsafe processDeadlines(w, configuration: configuration)
    if unsafe w.pointee.stopping && w.pointee.admissionClosed && w.pointee.activeCount == 0 {
      break
    }
  }
  // With lazy notification there is no registration left once no connection has work
  // in flight; anything still armed here would be an invariant violation worth
  // surfacing, and the queue is discarded when the completion queue is closed below.
  if unsafe w.pointee.notificationArmed {
    cesReport(stage: "server worker notification unarmed precondition", error: 5023)
  }
  unsafe w.pointee.phase = .stopped
  return unsafe configuration.failure.failed.load(ordering: .acquiring) ? 1 : 0
}
@c
package func cesWorkerThread(_ parameter: UnsafeMutableRawPointer?) -> DWORD {
  let w = unsafe parameter!.assumingMemoryBound(to: CESEngineWorker.self)
  return unsafe runWorker(w, configuration: w.pointee.configuration)
}
package func cesInitializeWorker(_ w: UnsafeMutablePointer<CESEngineWorker>) -> Bool {
  unsafe cesInitializeWorker(w, configuration: w.pointee.configuration)
}
private func cesInitializeWorker(
  _ w: UnsafeMutablePointer<CESEngineWorker>, configuration: borrowing CESWorkerConfiguration
) -> Bool {
  let c = unsafe Ref(configuration)
  // Capture each Win32 failure at its own call site: a later Win32 call would
  // overwrite the thread's last-error value.
  let portHandle = unsafe CreateIoCompletionPort(HANDLE(bitPattern: -1), nil, 0, 1)
  var portError: Int32 = 0
  if unsafe portHandle == nil { portError = Int32(bitPattern: GetLastError()) }
  unsafe w.pointee.resources.port.reset(portHandle)
  let readyHandle = unsafe CreateEventW(nil, true, false, nil)
  var readyError: Int32 = 0
  if unsafe readyHandle == nil { readyError = Int32(bitPattern: GetLastError()) }
  unsafe w.pointee.resources.readyEvent.reset(readyHandle)
  guard unsafe portHandle != nil else {
    cesReport(stage: "CreateIoCompletionPort(worker)", error: portError)
    return false
  }
  guard unsafe readyHandle != nil else {
    cesReport(stage: "CreateEvent(worker ready)", error: readyError)
    return false
  }
  let slotCount = unsafe w.pointee.slotCount
  guard slotCount > 0,
    let arenaBytes = unsafe cesCheckedArenaBytes(
      slots: UInt64(slotCount), stride: UInt64(w.pointee.stride), memoryLimit: c.value.memoryShare),
    arenaBytes <= UInt64(UInt32.max)
  else {
    cesReport(stage: "worker registered arena size", error: 8)
    return false
  }
  unsafe w.pointee.resources.arena.reset(
    VirtualAlloc(nil, arenaBytes, DWORD(UInt32(MEM_RESERVE) | UInt32(MEM_COMMIT)), DWORD(UInt32(PAGE_READWRITE))),
    byteCount: Int(arenaBytes))
  if let storage = unsafe CESPinnedStorage(
    count: Int(slotCount), initialValue: CESEngineConnection())
  {
    unsafe w.pointee.connectionAddress = unsafe storage.baseAddress
    unsafe w.pointee.resources.connections = unsafe consume storage
  }
  if let storage = unsafe CESPinnedStorage(count: Int(slotCount), initialValue: CESEngineRequest()) {
    unsafe w.pointee.requestAddress = unsafe storage.baseAddress
    unsafe w.pointee.resources.requests = unsafe consume storage
  }
  if let storage = unsafe CESPinnedStorage(count: 1, initialValue: OVERLAPPED()) {
    unsafe w.pointee.notificationAddress = unsafe storage.baseAddress
    unsafe w.pointee.resources.notification = unsafe consume storage
  }
  if let storage = unsafe CESPinnedStorage(
    count: CESConstants.completionBatchSize, initialValue: RIORESULT())
  {
    unsafe w.pointee.resultsAddress = unsafe storage.baseAddress
    unsafe w.pointee.resources.results = unsafe consume storage
  }
  guard let memory = unsafe w.pointee.resources.arena.rawValue,
    let connectionBase = unsafe w.pointee.connectionAddress,
    let requestBase = unsafe w.pointee.requestAddress,
    let notification = unsafe w.pointee.notificationAddress,
    unsafe w.pointee.resultsAddress != nil
  else {
    cesReport(stage: "worker allocation", error: 8)
    return false
  }
  unsafe w.pointee.memory = unsafe memory.assumingMemoryBound(to: UInt8.self)
  let first = UInt(bitPattern: requestBase)
  let (extent, extentOverflow) = unsafe UInt(MemoryLayout<CESEngineRequest>.stride)
    .multipliedReportingOverflow(by: UInt(slotCount))
  let (end, endOverflow) = first.addingReportingOverflow(extent)
  guard !extentOverflow && !endOverflow else {
    cesFailFast(stage: "server request allocation extent", error: 13)
  }
  unsafe w.pointee.requestRange = first..<end
  unsafe w.pointee.freeIndices.reserveCapacity(Int(slotCount))
  for index in 0..<slotCount {
    unsafe w.pointee.freeIndices.append(slotCount - index - 1)
    unsafe connectionBase[Int(index)].socket = ~SOCKET(0)
    unsafe connectionBase[Int(index)].requestQueue = nil
    unsafe connectionBase[Int(index)].owner = w
    unsafe connectionBase[Int(index)].index = index
    unsafe requestBase[Int(index)].connectionIndex = index
    unsafe requestBase[Int(index)].operation = .receive
    unsafe w.pointee.resources.sockets.append(CESSocketOwner())
  }
  unsafe w.pointee.freeCount = slotCount
  guard
    let registrationID = unsafe c.value.rio.RIORegisterBuffer!(
      memory.assumingMemoryBound(to: CChar.self), UInt32(arenaBytes))
  else {
    cesReport(stage: "RIORegisterBuffer(worker)", error: WSAGetLastError())
    return false
  }
  unsafe w.pointee.resources.registration.reset(rio: c.value.rio, value: registrationID)
  var completionNotification = unsafe RIO_NOTIFICATION_COMPLETION()
  unsafe completionNotification.Type = RIO_IOCP_COMPLETION
  unsafe completionNotification.Iocp.IocpHandle = unsafe w.pointee.resources.port.rawValue
  unsafe completionNotification.Iocp.CompletionKey = UnsafeMutableRawPointer(w)
  unsafe completionNotification.Iocp.Overlapped = UnsafeMutableRawPointer(notification)
  guard
    let completionQueue = unsafe c.value.rio.RIOCreateCompletionQueue!(
      slotCount * 2, &completionNotification)
  else {
    cesReport(stage: "RIOCreateCompletionQueue(worker)", error: WSAGetLastError())
    return false
  }
  unsafe w.pointee.resources.completionQueue.reset(rio: c.value.rio, value: completionQueue)
  for index in 0..<slotCount {
    let buffer = unsafe cesConnectionBuffer(connectionBase.advanced(by: Int(index)))
    unsafe buffer.pointee.BufferId = registrationID
    unsafe buffer.pointee.Offset = UInt32(UInt64(index) * UInt64(w.pointee.stride))
    unsafe buffer.pointee.Length = unsafe w.pointee.stride
  }
  unsafe w.pointee.resources.thread.reset(CreateThread(nil, 0, cesWorkerThread, w, 0, nil))
  if unsafe w.pointee.resources.thread.rawValue == nil {
    cesReport(stage: "CreateThread(worker)", error: Int32(bitPattern: GetLastError()))
    return false
  }
  guard
    unsafe WaitForSingleObject(w.pointee.resources.readyEvent.rawValue, UInt32.max)
      == WAIT_OBJECT_0,
    unsafe w.pointee.ready
  else {
    cesReport(stage: "worker startup readiness", error: 5023)
    return false
  }
  return true
}
package func cesPostWorkerStop(_ w: UnsafeMutablePointer<CESEngineWorker>) {
  let posted = unsafe PostQueuedCompletionStatus(
    w.pointee.resources.port.rawValue, 0, UInt64(CESConstants.stopKey), nil)
  cesRequireControlPostSuccess(
    posted, error: Int32(bitPattern: GetLastError()),
    stage: "PostQueuedCompletionStatus(worker stop)")
}
package func cesPostWorkerAdmissionClosed(_ w: UnsafeMutablePointer<CESEngineWorker>) {
  let posted = unsafe PostQueuedCompletionStatus(
    w.pointee.resources.port.rawValue, 0, UInt64(CESConstants.admissionClosedKey), nil)
  cesRequireControlPostSuccess(
    posted, error: Int32(bitPattern: GetLastError()),
    stage: "PostQueuedCompletionStatus(worker admission closed)")
}
package func cesDestroyWorker(_ w: UnsafeMutablePointer<CESEngineWorker>) {
  let ranThread = unsafe w.pointee.resources.thread.rawValue
  if let thread = unsafe ranThread {
    guard unsafe WaitForSingleObject(thread, UInt32.max) == WAIT_OBJECT_0 else {
      cesFailFast(stage: "server worker join", error: Int32(bitPattern: GetLastError()))
    }
    if unsafe w.pointee.ready {
      let phase: CESWorkerPhase =
        unsafe w.pointee.admissionClosed ? .admissionClosed : .draining
      let lifecycle = CESWorkerLifecycle(
        phase: phase, activeConnections: unsafe w.pointee.activeCount, pendingHandoffs: 0,
        notificationArmed: unsafe w.pointee.notificationArmed)
      guard cesWorkerMayExit(lifecycle), unsafe !w.pointee.notificationArmed,
        unsafe w.pointee.timers.size == 0
      else { cesFailFast(stage: "server worker release precondition", error: 5023) }
    }
    unsafe w.pointee.resources.thread.reset()
  }
  if unsafe ranThread != nil && w.pointee.configuration.options.stats {
    let statistics = unsafe CESEngineStatistics(
      accepted: w.pointee.acceptedCount, completions: w.pointee.completionCount,
      receives: w.pointee.receiveCount, sends: w.pointee.sendCount, bytes: w.pointee.echoedBytes)
    cesPrintWorkerStatistics(workerIndex: unsafe w.pointee.workerIndex, statistics: statistics, active: unsafe w.pointee.activeCount)
  }
  for index in unsafe 0..<w.pointee.resources.sockets.count {
    unsafe w.pointee.resources.sockets[index].reset()
  }
  unsafe w.pointee.resources.completionQueue.reset()
  unsafe w.pointee.resources.registration.reset()
  unsafe w.pointee.resources.arena.reset()
  unsafe w.pointee.memory = nil
  unsafe w.pointee.resources.sockets = UniqueArray()
  unsafe w.pointee.resources.connections = nil
  unsafe w.pointee.resources.requests = nil
  unsafe w.pointee.resources.notification = nil
  unsafe w.pointee.resources.results = nil
  unsafe w.pointee.freeIndices = UniqueArray()
  unsafe w.pointee.connectionAddress = nil
  unsafe w.pointee.requestAddress = nil
  unsafe w.pointee.notificationAddress = nil
  unsafe w.pointee.resultsAddress = nil
  unsafe w.pointee.requestRange = 0..<0
  unsafe w.pointee.timers = CESTimerHeap(capacity: 0)
  unsafe w.pointee.resources.readyEvent.reset()
  unsafe w.pointee.resources.port.reset()
}
