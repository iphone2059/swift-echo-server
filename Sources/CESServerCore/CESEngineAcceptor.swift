import WinSDK

// TCP admission. AcceptEx operations are pre-posted on a dedicated completion port;
// each accepted RIO socket is handed to a fixed worker through that worker's IOCP,
// and the worker acknowledges the handoff by posting the same operation key back.
// The acceptor outlives every handoff: the coordinator joins this thread before it
// publishes the admission-closed barrier.

package func cesAckAccept(_ operation: UnsafeMutablePointer<CESAcceptOperation>) {
  let posted = unsafe PostQueuedCompletionStatus(
    operation.pointee.acceptPort, 0, UInt64(UInt(bitPattern: operation)), nil)
  cesRequireControlPostSuccess(
    posted, error: Int32(bitPattern: GetLastError()),
    stage: "PostQueuedCompletionStatus(accept ack)")
}
package func cesAcceptorOperationForAddress(
  _ acceptor: UnsafeMutablePointer<CESEngineAcceptor>, address: UInt
) -> UnsafeMutablePointer<CESAcceptOperation>? {
  guard let base = unsafe acceptor.pointee.operationAddress else { return nil }
  let first = UInt(bitPattern: base)
  let stride = unsafe UInt(MemoryLayout<CESAcceptOperation>.stride)
  guard stride != 0 else { return nil }
  let (extent, extentOverflow) = stride.multipliedReportingOverflow(
    by: UInt(unsafe acceptor.pointee.operationCount))
  let (end, endOverflow) = first.addingReportingOverflow(extent)
  guard !extentOverflow, !endOverflow, address >= first, address < end,
    (address - first) % stride == 0
  else { return nil }
  let index = UInt32((address - first) / stride)
  let candidate = unsafe UnsafeMutablePointer<CESAcceptOperation>(bitPattern: address)
  guard let operation = unsafe candidate, unsafe operation.pointee.owner == acceptor,
    unsafe operation.pointee.index == index
  else { return nil }
  return unsafe operation
}
// Handing the accepted socket over through the operation record keeps the acceptor's
// owners out of every other thread: the acceptor releases the owner, the worker adopts
// the raw value, and whoever still holds it closes it.
private func transferAcceptSocket(
  _ acceptor: UnsafeMutablePointer<CESEngineAcceptor>,
  operation: UnsafeMutablePointer<CESAcceptOperation>
) {
  unsafe operation.pointee.socket = unsafe acceptor.pointee.resources.operationSockets[
    Int(operation.pointee.index)
  ].release()
}
private func closeTransferredSocket(_ operation: UnsafeMutablePointer<CESAcceptOperation>) {
  if unsafe operation.pointee.socket != ~SOCKET(0) {
    var stray = CESSocketOwner(unsafe operation.pointee.socket)
    stray.reset()
    unsafe operation.pointee.socket = ~SOCKET(0)
  }
}
// A peer that resets before AcceptEx completes aborts that single incoming
// connection; ERROR_NETNAME_DELETED is the documented outcome for it. Everything
// else keeps the baseline's fatal classification so that real listener or IOCP
// damage still stops admission instead of being retried forever.
private func cesAcceptErrorIsRecoverable(_ error: DWORD) -> Bool {
  error == DWORD(ERROR_NETNAME_DELETED)
}
private func closeAcceptSocket(_ operation: UnsafeMutablePointer<CESAcceptOperation>) {
  let acceptor = unsafe operation.pointee.owner!
  unsafe acceptor.pointee.resources.operationSockets[Int(operation.pointee.index)].reset()
  unsafe operation.pointee.socket = ~SOCKET(0)
}
private func postAccept(
  _ acceptor: UnsafeMutablePointer<CESEngineAcceptor>,
  operation: UnsafeMutablePointer<CESAcceptOperation>,
  configuration: borrowing CESAcceptorConfiguration
) -> Bool {
  guard let acceptEx = unsafe acceptor.pointee.acceptEx,
    let addressBase = unsafe acceptor.pointee.addressBuffer
  else { cesFailFast(stage: "server acceptor extensions", error: 13) }
  let overlapped = unsafe cesAcceptOverlapped(operation)
  unsafe overlapped.pointee = OVERLAPPED()
  let socket = cesRegisteredSocket(transport: .tcp)
  unsafe acceptor.pointee.resources.operationSockets[Int(operation.pointee.index)].reset(socket)
  unsafe operation.pointee.socket = socket
  guard socket != ~SOCKET(0) else {
    cesReport(stage: "WSASocketW(accepted RIO socket)", error: WSAGetLastError())
    return false
  }
  let buffer = unsafe UnsafeMutableRawPointer(addressBase.advanced(by: operation.pointee.addressOffset))
  var received: DWORD = 0
  unsafe operation.pointee.state = .posted
  let accepted = unsafe acceptEx(
    acceptor.pointee.resources.listener.rawValue, socket, buffer, 0,
    DWORD(CESConstants.acceptAddressBytes), DWORD(CESConstants.acceptAddressBytes), &received,
    overlapped)
  if !accepted.boolValue && WSAGetLastError() != 997 {
    cesReport(stage: "AcceptEx", error: WSAGetLastError())
    unsafe operation.pointee.state = .idle
    unsafe closeAcceptSocket(operation)
    return false
  }
  return true
}
private func acceptorHasLive(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) -> Bool {
  guard let base = unsafe acceptor.pointee.operationAddress else { return false }
  for index in 0..<Int(unsafe acceptor.pointee.operationCount) {
    if unsafe base[index].state != .idle { return true }
  }
  return false
}
private func closeListener(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) {
  unsafe acceptor.pointee.resources.listener.reset()
}
private func runAcceptor(
  _ acceptor: UnsafeMutablePointer<CESEngineAcceptor>,
  configuration: borrowing CESAcceptorConfiguration
) -> DWORD {
    guard let operations = unsafe acceptor.pointee.operationAddress else {
    cesFailFast(stage: "server acceptor operation table", error: 13)
  }
  let operationCount = unsafe acceptor.pointee.operationCount
  for index in 0..<Int(operationCount) {
    if unsafe !postAccept(
      acceptor, operation: operations.advanced(by: index), configuration: configuration)
    {
      unsafe configuration.failure.failed.store(true, ordering: .releasing)
      unsafe acceptor.pointee.stopping = true
      break
    }
  }
  while unsafe !acceptor.pointee.stopping || acceptorHasLive(acceptor) {
    var transferred: DWORD = 0
    var key: UInt64 = 0
    var overlap: UnsafeMutablePointer<OVERLAPPED>?
    let ok = unsafe GetQueuedCompletionStatus(
      acceptor.pointee.resources.port.rawValue, &transferred, &key, &overlap, 100)
    let waitError = ok ? 0 : GetLastError()
    if unsafe overlap == nil && key == CESConstants.stopKey {
      unsafe acceptor.pointee.stopping = true
      unsafe closeListener(acceptor)
      for index in 0..<Int(operationCount) {
        if unsafe operations[index].state == .posted {
          unsafe closeAcceptSocket(operations.advanced(by: index))
        }
      }
      continue
    }
    if unsafe overlap == nil && key > CESConstants.stopKey {
      guard
        let operation = unsafe cesAcceptorOperationForAddress(
          acceptor, address: UInt(key))
      else { cesFailFast(stage: "server accept acknowledgement identity", error: 13) }
      guard unsafe operation.pointee.state == .transit else {
        cesFailFast(stage: "server accept acknowledgement state", error: 13)
      }
      // The worker adopts or closes the socket before acknowledging; anything left
      // here is a stray the acceptor reclaims.
      unsafe closeTransferredSocket(operation)
      unsafe operation.pointee.state = .idle
      if unsafe !acceptor.pointee.stopping
        && !postAccept(acceptor, operation: operation, configuration: configuration)
      {
        unsafe configuration.failure.failed.store(true, ordering: .releasing)
        unsafe acceptor.pointee.stopping = true
        unsafe closeListener(acceptor)
      }
      continue
    }
    if let overlap = unsafe overlap {
      let candidate = UInt(bitPattern: unsafe cesAcceptOperation(overlap))
      guard
        let operation = unsafe cesAcceptorOperationForAddress(acceptor, address: candidate),
        unsafe cesAcceptOverlapped(operation) == overlap
      else { cesFailFast(stage: "server AcceptEx completion identity", error: 13) }
      guard unsafe operation.pointee.state == .posted else {
        cesFailFast(stage: "server AcceptEx completion state", error: 13)
      }
      // GetQueuedCompletionStatus already reports the I/O outcome: a successful
      // dequeue means AcceptEx succeeded, otherwise GetLastError holds the failure.
      // A second WSAGetOverlappedResult query is therefore redundant.
      let completed = ok
      let acceptError = waitError
      if !completed {
        unsafe operation.pointee.state = .idle
        unsafe closeAcceptSocket(operation)
        if unsafe acceptor.pointee.stopping { continue }
        if cesAcceptErrorIsRecoverable(acceptError) {
          // Connection-level abort: the accepted socket is gone, the listener is
          // healthy, so only this operation slot is reposted.
          if unsafe !postAccept(acceptor, operation: operation, configuration: configuration) {
            unsafe configuration.failure.failed.store(true, ordering: .releasing)
            unsafe acceptor.pointee.stopping = true
            unsafe closeListener(acceptor)
          }
          continue
        }
        cesReport(stage: "AcceptEx completion", error: Int32(bitPattern: acceptError))
        unsafe configuration.failure.failed.store(true, ordering: .releasing)
        unsafe acceptor.pointee.stopping = true
        unsafe closeListener(acceptor)
        continue
      }
      var listenerSocket = unsafe acceptor.pointee.resources.listener.rawValue
      let contextUpdated = withUnsafePointer(to: &listenerSocket) { pointer in
        unsafe setsockopt(
          operation.pointee.socket, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT,
          UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self),
          Int32(MemoryLayout<SOCKET>.size))
      }
      let configured = unsafe cesConfigureSocket(
        operation.pointee.socket, options: configuration.options, tcp: true)
      if contextUpdated != 0 || !configured {
        unsafe operation.pointee.state = .idle
        unsafe closeAcceptSocket(operation)
        unsafe configuration.failure.failed.store(true, ordering: .releasing)
        unsafe acceptor.pointee.stopping = true
        unsafe closeListener(acceptor)
        continue
      }
      // The AcceptEx output buffer is required by the API, but an echo server does not
      // consume the parsed peer address, so GetAcceptExSockaddrs is not loaded or called.
      guard let workers = unsafe configuration.workers, unsafe configuration.workerCount > 0
      else { cesFailFast(stage: "server acceptor worker table", error: 13) }
      let workerIndex = Int(unsafe acceptor.pointee.nextWorker % configuration.workerCount)
      unsafe acceptor.pointee.nextWorker &+= 1
      unsafe transferAcceptSocket(acceptor, operation: operation)
      unsafe operation.pointee.state = .transit
      let worker = unsafe workers.advanced(by: workerIndex)
      let posted = unsafe PostQueuedCompletionStatus(
        worker.pointee.resources.port.rawValue, 0, UInt64(UInt(bitPattern: operation)), nil)
      cesRequireControlPostSuccess(
        posted, error: Int32(bitPattern: GetLastError()),
        stage: "PostQueuedCompletionStatus(accept handoff)")
      continue
    }
    if !ok && waitError != WAIT_TIMEOUT {
      cesReport(stage: "GetQueuedCompletionStatus(acceptor)", error: Int32(bitPattern: waitError))
      unsafe configuration.failure.failed.store(true, ordering: .releasing)
      unsafe acceptor.pointee.stopping = true
      unsafe closeListener(acceptor)
    }
  }
  return unsafe configuration.failure.failed.load(ordering: .acquiring) ? 1 : 0
}
@c
package func cesAcceptorThread(_ parameter: UnsafeMutableRawPointer?) -> DWORD {
  let acceptor = unsafe parameter!.assumingMemoryBound(to: CESEngineAcceptor.self)
  return unsafe runAcceptor(acceptor, configuration: acceptor.pointee.configuration)
}
package func cesPostAcceptorStop(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) {
  let posted = unsafe PostQueuedCompletionStatus(
    acceptor.pointee.resources.port.rawValue, 0, UInt64(CESConstants.stopKey), nil)
  cesRequireControlPostSuccess(
    posted, error: Int32(bitPattern: GetLastError()),
    stage: "PostQueuedCompletionStatus(acceptor stop)")
}
package func cesInitializeAcceptor(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) -> Bool {
  unsafe cesInitializeAcceptor(acceptor, configuration: acceptor.pointee.configuration)
}
private func cesInitializeAcceptor(
  _ acceptor: UnsafeMutablePointer<CESEngineAcceptor>,
  configuration: borrowing CESAcceptorConfiguration
) -> Bool {
    unsafe acceptor.pointee.resources.listener.reset(cesRegisteredSocket(transport: .tcp))
  unsafe acceptor.pointee.resources.port.reset(
    CreateIoCompletionPort(HANDLE(bitPattern: -1), nil, 0, 1))
  let listener = unsafe acceptor.pointee.resources.listener.rawValue
  let port = unsafe acceptor.pointee.resources.port.rawValue
  guard listener != ~SOCKET(0) else {
    cesReport(stage: "WSASocketW(listener)", error: WSAGetLastError())
    return false
  }
  guard unsafe port != nil else {
    cesReport(
      stage: "CreateIoCompletionPort(acceptor)", error: Int32(bitPattern: GetLastError()))
    return false
  }
  guard unsafe cesConfigureSocket(listener, options: configuration.options, tcp: true) else {
    return false
  }
  // A zeroed SOCKADDR_IN binds the wildcard address, matching the baseline.
  var address = SOCKADDR_IN()
  address.sin_family = UInt16(AF_INET)
  address.sin_port = unsafe htons(configuration.options.port)
  let bound = withUnsafePointer(to: &address) {
    unsafe bind(
      listener, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self),
      Int32(MemoryLayout<SOCKADDR_IN>.size))
  }
  guard bound == 0, listen(listener, SOMAXCONN) == 0 else {
    cesReport(stage: "bind/listen", error: WSAGetLastError())
    return false
  }
  guard
    unsafe CreateIoCompletionPort(HANDLE(bitPattern: UInt(listener)), port, 0, 1) == port
  else {
    cesReport(
      stage: "CreateIoCompletionPort(listener association)",
      error: Int32(bitPattern: GetLastError()))
    return false
  }
  do {
    unsafe acceptor.pointee.acceptEx = unsafe try cesLoadAcceptEx(listener: listener)
  } catch {
    cesReport(stage: error.stage, error: error.code)
    return false
  }
  let possible = unsafe UInt64(configuration.workerCount) * UInt64(CESConstants.acceptsPerWorker)
  let operationCount = UInt32(min(possible, UInt64(CESConstants.maximumAccepts)))
  guard operationCount > 0 else {
    cesReport(stage: "AcceptEx operation count", error: 8)
    return false
  }
  unsafe acceptor.pointee.operationCount = operationCount
  if let storage = unsafe CESPinnedStorage(
    count: Int(operationCount), initialValue: CESAcceptOperation())
  {
    unsafe acceptor.pointee.operationAddress = unsafe storage.baseAddress
    unsafe acceptor.pointee.resources.operations = unsafe consume storage
  }
  if let storage = unsafe CESPinnedStorage(
    count: Int(operationCount) * CESConstants.acceptBufferBytes, initialValue: UInt8(0))
  {
    unsafe acceptor.pointee.addressBuffer = unsafe storage.baseAddress
    unsafe acceptor.pointee.resources.addresses = unsafe consume storage
  }
  guard let operations = unsafe acceptor.pointee.operationAddress,
    unsafe acceptor.pointee.addressBuffer != nil
  else {
    cesReport(stage: "AcceptEx operation allocation", error: 8)
    return false
  }
  // A completion OVERLAPPED address must map back to its record origin; the layout
  // is verified before any AcceptEx is posted.
  guard unsafe MemoryLayout<CESAcceptOperation>.offset(of: \CESAcceptOperation.overlapped) == 0
  else { cesFailFast(stage: "server accept operation layout", error: 13) }
  for index in 0..<Int(operationCount) {
    unsafe operations[index].owner = acceptor
    unsafe operations[index].socket = ~SOCKET(0)
    unsafe operations[index].acceptPort = port
    unsafe operations[index].addressOffset = index * CESConstants.acceptBufferBytes
    unsafe operations[index].index = UInt32(index)
    unsafe operations[index].state = .idle
    unsafe acceptor.pointee.resources.operationSockets.append(CESSocketOwner())
  }
  unsafe acceptor.pointee.resources.thread.reset(
    CreateThread(nil, 0, cesAcceptorThread, acceptor, 0, nil))
  if unsafe acceptor.pointee.resources.thread.rawValue == nil {
    cesReport(stage: "CreateThread(acceptor)", error: Int32(bitPattern: GetLastError()))
    return false
  }
  return true
}
package func cesDestroyAcceptor(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) {
  if let thread = unsafe acceptor.pointee.resources.thread.rawValue {
    guard unsafe WaitForSingleObject(thread, UInt32.max) == WAIT_OBJECT_0 else {
      cesFailFast(stage: "server acceptor join", error: Int32(bitPattern: GetLastError()))
    }
    unsafe acceptor.pointee.resources.thread.reset()
  }
  unsafe acceptor.pointee.resources.listener.reset()
  for index in unsafe 0..<acceptor.pointee.resources.operationSockets.count {
    unsafe acceptor.pointee.resources.operationSockets[index].reset()
  }
  // A socket that was transferred for handoff but never adopted is closed here.
  if let operations = unsafe acceptor.pointee.operationAddress {
    for index in 0..<Int(unsafe acceptor.pointee.operationCount) {
      unsafe closeTransferredSocket(operations.advanced(by: index))
    }
  }
  unsafe acceptor.pointee.resources.operationSockets = UniqueArray()
  unsafe acceptor.pointee.resources.operations = nil
  unsafe acceptor.pointee.resources.addresses = nil
  unsafe acceptor.pointee.operationAddress = nil
  unsafe acceptor.pointee.addressBuffer = nil
  unsafe acceptor.pointee.resources.port.reset()
}
