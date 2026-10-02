import Foundation
import WinSDK

// UDP engine. A fixed depth of RIOReceiveEx requests is kept posted; each receive
// completion turns its slot into a RIOSendEx echo of exactly the received bytes and
// then restores the receive. Stop closes the socket first to cancel outstanding
// requests, keeps draining completions, and only then releases the registered arena.
// There is no fallback data path: every payload moves through the RIO arena.
/// Completion batch size of the UDP engine's single completion queue.
private let cesUdpBatchSize = 256
private func cesRunUDP(
  rio: RIO_EXTENSION_FUNCTION_TABLE, options: borrowing CESOptions, control: CESSharedControl
) -> CESExitCode {
  let stride = UInt64(options.rioBufferBytes) + UInt64(CESConstants.udpAddressBytes)
  guard options.udpDepth <= options.cqCapacity / 2,
    let arenaBytes = cesCheckedArenaBytes(
      slots: UInt64(options.udpDepth), stride: stride, memoryLimit: options.memoryBytes),
    arenaBytes <= UInt64(UInt32.max)
  else {
    cesReport(stage: "UDP queue/arena capacity", error: 8)
    return .network
  }
  // Stable slot and notification storage. Windows borrows these addresses for the
  // whole run; they are released only after outstanding reaches zero.
  let slotCount = Int(options.udpDepth)
  let emptySlot = unsafe CESUdpSlot()
  let slotAddress = UnsafeMutablePointer<CESUdpSlot>.allocate(capacity: slotCount)
  unsafe slotAddress.initialize(repeating: emptySlot, count: slotCount)
  defer {
    unsafe slotAddress.deinitialize(count: slotCount)
    unsafe slotAddress.deallocate()
  }
  let notificationAddress = UnsafeMutablePointer<OVERLAPPED>.allocate(capacity: 1)
  unsafe notificationAddress.initialize(to: OVERLAPPED())
  defer {
    unsafe notificationAddress.deinitialize(count: 1)
    unsafe notificationAddress.deallocate()
  }
  // Each startup failure captures the error of the API that failed, immediately at the
  // call site: Winsock for the socket, Win32 for the IOCP and the arena allocation.
  let socketRaw = cesRegisteredSocket(transport: .udp)
  var socketError: Int32 = 0
  if socketRaw == ~SOCKET(0) { socketError = WSAGetLastError() }
  var socketOwner = CESSocketOwner(socketRaw)
  var socketValue = socketOwner.rawValue
  let portHandle = unsafe CreateIoCompletionPort(HANDLE(bitPattern: -1), nil, 0, 1)
  var portError: Int32 = 0
  if unsafe portHandle == nil { portError = Int32(bitPattern: GetLastError()) }
  let portOwner = unsafe CESHandleOwner(portHandle)
  let arenaRaw = unsafe VirtualAlloc(
    nil, arenaBytes, DWORD(UInt32(MEM_RESERVE) | UInt32(MEM_COMMIT)), DWORD(UInt32(PAGE_READWRITE)))
  var arenaError: Int32 = 0
  if unsafe arenaRaw == nil { arenaError = Int32(bitPattern: GetLastError()) }
  let arenaOwner = unsafe CESVirtualArenaOwner(arenaRaw, byteCount: Int(arenaBytes))
  var registrationOwner = unsafe CESRIORegistrationOwner()
  var completionQueueOwner = unsafe CESRIOCQOwner()
  let port = unsafe portOwner.rawValue
  let memory = unsafe arenaOwner.rawValue
  var armed = false
  var outstanding: UInt32 = 0
  var failed = false
  var phase: CESUDPPhase = .running
  var statistics = CESEngineStatistics()
  var registration: RIO_BUFFERID? = nil
  var completionQueue: RIO_CQ? = nil
  var requestQueue: RIO_RQ? = nil
  if socketValue == ~SOCKET(0) {
    cesReport(stage: "WSASocketW(UDP)", error: socketError)
    failed = true
  } else if !cesConfigureSocket(socketValue, options: options, tcp: false) {
    failed = true
  } else if unsafe port == nil {
    cesReport(stage: "CreateIoCompletionPort(UDP)", error: portError)
    failed = true
  } else if unsafe memory == nil {
    cesReport(stage: "VirtualAlloc(UDP arena)", error: arenaError)
    failed = true
  }
  if !failed {
    // A zeroed SOCKADDR_IN binds the wildcard address, matching the baseline.
    var address = SOCKADDR_IN()
    address.sin_family = UInt16(AF_INET)
    address.sin_port = htons(options.port)
    let bound = withUnsafePointer(to: &address) {
      unsafe bind(
        socketValue, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self),
        Int32(MemoryLayout<SOCKADDR_IN>.size))
    }
    if bound != 0 {
      cesReport(stage: "bind(UDP)", error: WSAGetLastError())
      failed = true
    }
  }
  if !failed, let memory = unsafe memory, let port = unsafe port {
    unsafe registration = rio.RIORegisterBuffer!(
      memory.assumingMemoryBound(to: CChar.self), UInt32(arenaBytes))
    if let value = unsafe registration {
      unsafe registrationOwner.reset(rio: rio, value: value)
    }
    var completion = unsafe RIO_NOTIFICATION_COMPLETION()
    unsafe completion.Type = RIO_IOCP_COMPLETION
    unsafe completion.Iocp.IocpHandle = port
    unsafe completion.Iocp.CompletionKey = UnsafeMutableRawPointer(slotAddress)
    unsafe completion.Iocp.Overlapped = UnsafeMutableRawPointer(notificationAddress)
    unsafe completionQueue = rio.RIOCreateCompletionQueue!(options.cqCapacity, &completion)
    if let value = unsafe completionQueue {
      unsafe completionQueueOwner.reset(rio: rio, value: value)
    }
    if unsafe registration == nil || completionQueue == nil {
      cesReport(stage: "UDP RIO buffer/CQ creation", error: WSAGetLastError())
      failed = true
    }
  } else if !failed {
    cesReport(stage: "UDP runtime allocation", error: 8)
    failed = true
  }
  if !failed, let completionQueue = unsafe completionQueue {
    unsafe requestQueue = rio.RIOCreateRequestQueue!(
      socketValue, options.udpDepth, 1, options.udpDepth, 1, completionQueue, completionQueue,
      UnsafeMutableRawPointer(slotAddress))
    if unsafe requestQueue == nil {
      cesReport(stage: "RIOCreateRequestQueue(UDP)", error: WSAGetLastError())
      failed = true
    }
  }
  if !failed, let requestQueue = unsafe requestQueue, let registration = unsafe registration {
    for index in 0..<Int(options.udpDepth) {
      let slot = unsafe slotAddress.advanced(by: index)
      unsafe slot.pointee.index = UInt32(index)
      unsafe slot.pointee.payload.BufferId = registration
      unsafe slot.pointee.payload.Offset = UInt32(UInt64(index) * stride)
      unsafe slot.pointee.payload.Length = options.rioBufferBytes
      unsafe slot.pointee.remoteAddress.BufferId = registration
      unsafe slot.pointee.remoteAddress.Offset = UInt32(
        UInt64(index) * stride + UInt64(options.rioBufferBytes))
      unsafe slot.pointee.remoteAddress.Length = UInt32(CESConstants.udpAddressBytes)
      unsafe slot.pointee.operation = .receive
      unsafe slot.pointee.outstanding = true
      let posted = unsafe rio.RIOReceiveEx!(
        requestQueue, &slot.pointee.payload, 1, nil, &slot.pointee.remoteAddress, nil, nil, 0,
        UnsafeMutableRawPointer(slot))
      if posted == 0 {
        cesReport(stage: "RIOReceiveEx(UDP)", error: WSAGetLastError())
        unsafe slot.pointee.outstanding = false
        failed = true
        break
      }
      outstanding += 1
    }
  }
  let start = GetTickCount64()
  var closing = failed
  if closing && socketValue != ~SOCKET(0) {
    socketOwner.reset()
    socketValue = ~SOCKET(0)
  }
  // SE-0531 (LiteralExpressions) would let the type argument be written as a named
  // constant; on this 6.5-dev snapshot the evaluator rejects both a static member and a
  // file-scope binding in a package build, so the literal stays and the name is used at
  // the runtime call sites instead (cesUdpBatchSize below).
  var results = InlineArray<256, RIORESULT>(repeating: RIORESULT())
  // The run deadline is precomputed: the right operand of '&&'/'||' is an
  // autoclosure, which cannot capture a borrowed parameter.
  let runDeadline =
    options.runSeconds == 0 ? UInt64.max : start + UInt64(options.runSeconds) * 1000
  while !closing || outstanding != 0 {
    // Lazy notification: a registration exists only while requests are in flight.
    // RIONotify called with a non-empty queue notifies immediately, so a completion
    // that arrives between the post and this arm cannot be lost.
    if outstanding != 0 && !armed {
      unsafe cesArmUDP(
        rio: rio, queue: completionQueue, overlapped: notificationAddress, armed: &armed)
    }
    let expired = GetTickCount64() >= runDeadline
    let stopNow = control.stopRequested.load(ordering: .acquiring)
    if !closing && (stopNow || expired) {
      closing = true
      phase = .draining
      socketOwner.reset()
      socketValue = ~SOCKET(0)
    }
    var transferred: DWORD = 0
    var key: UInt64 = 0
    var overlap: UnsafeMutablePointer<OVERLAPPED>?
    let ok = unsafe GetQueuedCompletionStatus(port, &transferred, &key, &overlap, 100)
    let error = ok ? 0 : GetLastError()
    if unsafe overlap == notificationAddress {
      if !ok {
        cesFailFast(
          stage: "GetQueuedCompletionStatus(UDP notification)",
          error: Int32(bitPattern: error))
      }
      unsafe cesRequireNotificationPacket(
        key: UInt(key), overlapped: overlap, expectedKey: UInt(bitPattern: slotAddress),
        expectedOverlapped: notificationAddress, stage: "server UDP RIO notification key")
      if !cesNotificationMarkDelivered(&armed) {
        cesFailFast(stage: "server UDP notification delivery transition", error: 5023)
      }
      // Bounded drain: yields to the control path after a fixed number of batches.
      for _ in 0..<64 {
        var view = results.mutableSpan
        let count = view.withUnsafeMutableBufferPointer {
          unsafe cesRequireValidDequeueCount(
            rio.RIODequeueCompletion!(
              unsafe completionQueue, $0.baseAddress, UInt32(cesUdpBatchSize)),
            stage: "RIODequeueCompletion(UDP)")
        }
        if count == 0 { break }
        guard Int(count) <= cesUdpBatchSize else {
          cesFailFast(stage: "server UDP dequeue batch", error: 13)
        }
        for resultIndex in 0..<Int(count) {
          let result = results[resultIndex]
          guard
            let slot = unsafe cesUdpSlotForAddress(
              slots: slotAddress, count: slotCount, address: UInt(result.RequestContext)),
            unsafe slot.pointee.outstanding, outstanding != 0
          else { cesFailFast(stage: "server UDP completion invariant", error: 13) }
          unsafe slot.pointee.outstanding = false
          outstanding -= 1
          statistics.completions &+= 1
          if unsafe slot.pointee.operation == .receive {
            statistics.receives &+= 1
          } else {
            statistics.sends &+= 1
            if result.Status == 0 { statistics.bytes &+= UInt64(result.BytesTransferred) }
          }
          if closing { continue }
          if result.Status != 0 {
            if result.Status == Int32(bitPattern: UInt32(WSAECONNRESET)) {
              unsafe slot.pointee.operation = .receive
            } else {
              cesReport(stage: "UDP RIO completion", error: result.Status)
              failed = true
              closing = true
              socketOwner.reset()
              socketValue = ~SOCKET(0)
              continue
            }
          } else if unsafe slot.pointee.operation == .receive {
            unsafe slot.pointee.payload.Length = result.BytesTransferred
            unsafe slot.pointee.operation = .send
          } else {
            unsafe slot.pointee.payload.Length = options.rioBufferBytes
            unsafe slot.pointee.operation = .receive
          }
          var posted = false
          if unsafe slot.pointee.operation == .send {
            posted = unsafe rio.RIOSendEx!(
              requestQueue, &slot.pointee.payload, 1, nil, &slot.pointee.remoteAddress, nil, nil, 0,
              UnsafeMutableRawPointer(slot)
            ).boolValue
          } else {
            let value = unsafe rio.RIOReceiveEx!(
              requestQueue, &slot.pointee.payload, 1, nil, &slot.pointee.remoteAddress, nil, nil, 0,
              UnsafeMutableRawPointer(slot))
            posted = value != 0
          }
          if !posted {
            cesReport(stage: "UDP RIO repost", error: WSAGetLastError())
            failed = true
            closing = true
            socketOwner.reset()
            socketValue = ~SOCKET(0)
            continue
          }
          unsafe slot.pointee.outstanding = true
          outstanding += 1
        }
        // A saturated peer can keep the queue non-empty forever: every processed
        // completion is reposted immediately. Cancelling outstanding work as soon as
        // stop or the run deadline is observed stops the reposting, so the drain
        // converges; pending results stay queued and the re-armed notification
        // delivers them.
        let drainExpired = GetTickCount64() >= runDeadline
        let drainStop = control.stopRequested.load(ordering: .acquiring)
        if !closing && (drainStop || drainExpired) {
          closing = true
          phase = .draining
          socketOwner.reset()
          socketValue = ~SOCKET(0)
        }
      }
    } else if !ok && error != WAIT_TIMEOUT {
      cesFailFast(stage: "GetQueuedCompletionStatus(UDP)", error: Int32(bitPattern: error))
    } else if unsafe !(!ok && error == WAIT_TIMEOUT && overlap == nil) {
      cesFailFast(stage: "unexpected UDP IOCP packet", error: 13)
    }
  }
  phase = .stopped
  if failed && socketValue != ~SOCKET(0) {
    socketOwner.reset()
    socketValue = ~SOCKET(0)
  }
  // With lazy notification there is no registration left once nothing is in flight;
  // anything still armed here would be an invariant violation worth surfacing, and the
  // queue is discarded when the completion queue is closed below.
  if armed {
    cesReport(stage: "server UDP notification unarmed precondition", error: 5023)
  }
  if !cesUdpMayRelease(phase: phase, outstanding: outstanding) {
    cesFailFast(stage: "UDP cleanup with outstanding operations", error: 997)
  }
  if options.stats {
    cesPrintFinalStatistics(
      protocolKind: .udp, statistics: statistics,
      elapsedMilliseconds: GetTickCount64() - start, terminalCount: outstanding)
  }
  return failed ? .network : .success
}
package func cesArmUDP(
  rio: RIO_EXTENSION_FUNCTION_TABLE, queue: RIO_CQ?,
  overlapped: UnsafeMutablePointer<OVERLAPPED>, armed: inout Bool
) {
  if armed { cesFailFast(stage: "server duplicate UDP RIONotify", error: 5023) }
  unsafe overlapped.pointee = OVERLAPPED()
  cesRequireRIONotifySuccess(unsafe rio.RIONotify!(queue), stage: "RIONotify(UDP)")
  if !cesNotificationMarkRearmed(&armed) {
    cesFailFast(stage: "server UDP notification rearm transition", error: 5023)
  }
}
// A completion context is only accepted when it lies inside the slot allocation,
// is stride aligned and still describes a live slot. Both extent products are
// overflow checked, matching the TCP request-context validation.
package func cesUdpSlotForAddress(
  slots: UnsafeMutablePointer<CESUdpSlot>, count: Int, address: UInt
) -> UnsafeMutablePointer<CESUdpSlot>? {
  guard count > 0 else { return nil }
  let first = UInt(bitPattern: slots)
  let stride = unsafe UInt(MemoryLayout<CESUdpSlot>.stride)
  guard stride != 0 else { return nil }
  let (extent, extentOverflow) = stride.multipliedReportingOverflow(by: UInt(count))
  let (end, endOverflow) = first.addingReportingOverflow(extent)
  guard !extentOverflow, !endOverflow, address >= first, address < end,
    (address - first) % stride == 0
  else { return nil }
  let index = UInt32((address - first) / stride)
  let candidate = unsafe UnsafeMutablePointer<CESUdpSlot>(bitPattern: address)
  guard let slot = unsafe candidate, unsafe slot.pointee.index == index else { return nil }
  return unsafe slot
}
package func cesRunUDPServer(
  rio: RIO_EXTENSION_FUNCTION_TABLE, options: borrowing CESOptions, control: CESSharedControl
) -> CESExitCode {
  cesRunUDP(rio: rio, options: options, control: control)
}
