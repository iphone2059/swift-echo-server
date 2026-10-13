import Synchronization
import WinSDK

// Pure state modules. None of these types contains a socket, RQ, OVERLAPPED or
// provider ledger; runtimes below are the only bridge to the native transport.
package enum CESConnectionState { case idle, receiving, sending, closing, released }
package enum CESConnectionStep {
  case none, receive, send(offset: UInt32, length: UInt32), close, release
}
package struct CESConnection {
  package var index: UInt32 = 0
  package var state: CESConnectionState = .idle
  package var outstanding: UInt32 = 0
  package var echoBytes: UInt32 = 0
  package var sendOffset: UInt32 = 0
  package var deadline: UInt64 = 0
  package var isActive: Bool { state == .receiving || state == .sending || state == .closing }
  package mutating func admit(now: UInt64, timeout: UInt64) {
    state = .receiving; outstanding = 0; echoBytes = 0; sendOffset = 0
    deadline = cesSaturatingAdd(now, timeout)
  }
  package mutating func close(now: UInt64) -> CESConnectionStep {
    if !isActive || state == .closing { return .none }
    state = .closing; deadline = cesSaturatingAdd(now, CESConstants.drainGraceMilliseconds)
    return outstanding == 0 ? release() : .close
  }
  private mutating func release() -> CESConnectionStep {
    state = .released; outstanding = 0; echoBytes = 0; sendOffset = 0; deadline = 0
    return .release
  }
  package mutating func onCompletion(_ c: CESCompletion, now: UInt64, timeout: UInt64) -> CESConnectionStep {
    // Aggregate verifies active state and the matching posted intent first.
    if outstanding == 0 { cesFailFast(stage: "server completion without provider ownership", error: 13) }
    outstanding -= 1
    if state == .closing { return outstanding == 0 ? release() : .none }
    if c.status != 0 || (c.operation == .receive && c.bytes == 0) { return close(now: now) }
    deadline = cesSaturatingAdd(now, timeout)
    if c.operation == .receive {
      echoBytes = c.bytes; sendOffset = 0; state = .sending
    } else {
      if c.bytes == 0 || sendOffset > echoBytes || c.bytes > echoBytes - sendOffset { return close(now: now) }
      sendOffset += c.bytes
      if sendOffset == echoBytes { state = .receiving }
    }
    if state == .receiving { return .receive }
    return .send(offset: sendOffset, length: echoBytes - sendOffset)
  }
}
package struct CESUdpSlotState {
  package var operation: CESEngineOperation = .receive
  package var length: UInt32 = 0
  package var outstanding = false
}
package enum CESUdpAction: Equatable {
  case post(index: UInt32, operation: CESEngineOperation, length: UInt32), fatal(CESFailure), none
}
package struct CESUdpEngine: ~Copyable {
  private var slots: CESFixedArray<CESUdpSlotState>
  package let depth: UInt32
  private let payloadBytes: UInt32
  package private(set) var outstanding: UInt32 = 0
  package private(set) var phase: CESUDPPhase = .running
  package private(set) var closing = false
  package private(set) var failed = false
  package var statistics = CESEngineStatistics()
  package var failure: CESFailure?
  package init(depth: UInt32, payloadBytes: UInt32) {
    self = try! CESUdpEngine(checkedDepth: depth, payloadBytes: payloadBytes)
  }
  package init(checkedDepth: UInt32, payloadBytes: UInt32) throws(CESFailure) {
    depth = checkedDepth; self.payloadBytes = payloadBytes
    slots = try CESFixedArray(count: Int(checkedDepth), repeating: CESUdpSlotState(length: payloadBytes))
  }
  package borrowing func slot(_ index: UInt32) -> CESUdpSlotState? { index < depth ? slots[Int(index)] : nil }
  package mutating func markPosted(index: UInt32, operation: CESEngineOperation) -> Bool {
    guard index < depth && !closing && !slots[Int(index)].outstanding && slots[Int(index)].operation == operation else { return false }
    slots[Int(index)].outstanding = true; outstanding += 1; return true
  }
  package mutating func onEvent(_ event: CESEvent) -> CESUdpAction {
    switch event {
    case .stop: closing = true; phase = .draining; return .none
    case .generationDrained:
      guard closing && outstanding == 0 else { return .fatal(.invariant("UDP generation drain")) }
      phase = .stopped; return .none
    case .admissionClosed: return .fatal(.invariant("UDP engine event"))
    case .postFailed(let i, let f):
      guard i < depth && !slots[Int(i)].outstanding else { return .fatal(.invariant("UDP refused post ownership")) }
      statistics.networkErrors &+= 1
      failed = true; closing = true; phase = .draining; failure = f
      return .fatal(f)
    case .completion(let c):
      guard c.index < depth && outstanding != 0 && slots[Int(c.index)].outstanding && slots[Int(c.index)].operation == c.operation else {
        return .fatal(.invariant("UDP completion invariant"))
      }
      slots[Int(c.index)].outstanding = false; outstanding -= 1
      statistics.record(c, closing: closing)
      if closing { return .none }
      if c.status != 0 {
        if c.status != 10054 {
          let f = CESFailure(stage: "UDP RIO completion", code: c.status)
          failed = true; closing = true; phase = .draining; failure = f; return .fatal(f)
        }
        slots[Int(c.index)].operation = .receive; slots[Int(c.index)].length = payloadBytes
      } else if c.operation == .receive {
        slots[Int(c.index)].operation = .send; slots[Int(c.index)].length = c.bytes
      } else {
        slots[Int(c.index)].operation = .receive; slots[Int(c.index)].length = payloadBytes
      }
      let s = slots[Int(c.index)]
      return .post(index: c.index, operation: s.operation, length: s.length)
    }
  }
  package var mayRelease: Bool { cesUdpMayRelease(phase: phase, outstanding: outstanding) }
}

package final class CESAdmissionCredits: Sendable {
  private let available: Atomic<UInt32>
  package let capacity: UInt32
  package init(capacity: UInt32) { self.capacity = capacity; available = Atomic(capacity) }
  package func tryReserve() -> Bool {
    var old = available.load(ordering: .acquiring)
    while old != 0 {
      let result = available.compareExchange(expected: old, desired: old - 1, ordering: .acquiringAndReleasing)
      if result.exchanged { return true }
      old = result.original
    }
    return false
  }
  package func release() {
    var old = available.load(ordering: .acquiring)
    while true {
      if old >= capacity { cesFailFast(stage: "worker admission credit", error: 5023) }
      let result = available.compareExchange(expected: old, desired: old + 1, ordering: .acquiringAndReleasing)
      if result.exchanged { return }
      old = result.original
    }
  }
  package var isFull: Bool { available.load(ordering: .acquiring) == capacity }
}
package enum CESAcceptState { case idle, posted, transit, deferred }
package enum CESAcceptEvent {
  case completion(index: UInt32, succeeded: Bool, code: UInt32, admissionFailed: Bool)
  case acknowledged(index: UInt32), stop
}
package enum CESAcceptAction {
  case handoff(index: UInt32, worker: UInt32), repost(index: UInt32), drop(index: UInt32), fatal(CESFailure)
}
package struct CESAcceptorCore: ~Copyable {
  package var states: CESFixedArray<CESAcceptState>
  private var credits: CESFixedArray<CESAdmissionCredits?>
  private let workerCount: UInt32
  package var stopping = false
  package var nextWorker: UInt32 = 0
  package var statistics = CESEngineStatistics()
  package init(count: UInt32, workers: UInt32 = 1) throws(CESFailure) {
    guard workers != 0 && workers <= CESConstants.maximumWorkers else { throw .invariant("server acceptor worker table") }
    workerCount = workers
    states = try CESFixedArray(count: Int(count), repeating: .idle)
    credits = try CESFixedArray(count: Int(workers), repeating: Optional<CESAdmissionCredits>.none)
  }
  package mutating func assignCredit(index: UInt32, credit: CESAdmissionCredits) { credits[Int(index)] = credit }
  package mutating func reserveWorker(candidate: UInt32) -> UInt32? {
    nextWorker = candidate % workerCount
    for offset in 0..<workerCount {
      let index = (candidate + offset) % workerCount
      if let credit = credits[Int(index)], credit.tryReserve() { nextWorker = (index + 1) % workerCount; return index }
    }
    return nil
  }
  package var liveCount: UInt32 {
    var result: UInt32 = 0
    for i in 0..<states.count { if states[i] != .idle { result += 1 } }
    return result
  }
  package mutating func markPosted(index: UInt32) -> Bool {
    guard Int(index) < states.count && states[Int(index)] == .idle && !stopping else { return false }
    states[Int(index)] = .posted; return true
  }
  package mutating func returnSlot(index: UInt32) { states[Int(index)] = .idle }
  package mutating func deferRepost(index: UInt32) { states[Int(index)] = .deferred }
  package mutating func onEvent(_ event: CESAcceptEvent) -> CESAcceptAction {
    switch event {
    case .completion(let index, let succeeded, let code, let failed): return onCompletion(index: index, succeeded: succeeded, code: code, admissionFailed: failed)
    case .acknowledged(let index): return onAck(index: index)
    case .stop: stopping = true; return .drop(index: 0)
    }
  }
  package mutating func onCompletion(index: UInt32, succeeded: Bool, code: UInt32, admissionFailed: Bool = false) -> CESAcceptAction {
    guard Int(index) < states.count && states[Int(index)] == .posted else { return .fatal(.invariant("server AcceptEx completion state")) }
    if stopping || admissionFailed { states[Int(index)] = .idle; return .drop(index: index) }
    if !succeeded {
      states[Int(index)] = .idle; statistics.networkErrors &+= 1
      if cesAcceptErrorIsRecoverable(code) { return .repost(index: index) }
      return .fatal(CESFailure(domain: .win32, stage: "AcceptEx completion", code: Int32(bitPattern: code)))
    }
    states[Int(index)] = .transit
    let candidate = nextWorker % workerCount; nextWorker = (candidate + 1) % workerCount
    return .handoff(index: index, worker: candidate)
  }
  package mutating func onAck(index: UInt32) -> CESAcceptAction {
    guard Int(index) < states.count && (states[Int(index)] == .transit || states[Int(index)] == .deferred) else { return .fatal(.invariant("server accept acknowledgement state")) }
    states[Int(index)] = .idle
    return stopping ? .drop(index: index) : .repost(index: index)
  }
}
package func cesAcceptErrorIsRecoverable(_ error: UInt32) -> Bool { error == 64 || error == 10054 || error == 10053 }
// Per-worker index minimum heap. Deadlines are worker-private: only the owning
// thread inserts, updates and removes entries, and the IOCP wait is taken from
// the nearest deadline instead of scanning every connection.
package struct CESTimerNode {
  package var deadline: UInt64 = 0
  package var connectionIndex: UInt32 = 0
}
package struct CESTimerHeap: ~Copyable {
  package let capacity: Int
  package private(set) var size = 0
  // Fallible fixed storage is allocated once. No insertion reallocates; exceeding
  // capacity is an explicit invariant refusal, independent of toolchain containers.
  private var nodes: CESFixedArray<CESTimerNode>
  private var positions: CESFixedArray<Int>
  package init(capacity: UInt32) {
    self = try! CESTimerHeap(checkedCapacity: capacity)
  }
  package init(checkedCapacity: UInt32) throws(CESFailure) {
    capacity = Int(checkedCapacity)
    nodes = try CESFixedArray(count: capacity, repeating: CESTimerNode())
    positions = try CESFixedArray(count: capacity, repeating: -1)
  }
  private borrowing func less(_ a: Int, _ b: Int) -> Bool {
    nodes[a].deadline == nodes[b].deadline
      ? nodes[a].connectionIndex < nodes[b].connectionIndex : nodes[a].deadline < nodes[b].deadline
  }
  private mutating func swap(_ a: Int, _ b: Int) {
    let temporary = nodes[a]
    nodes[a] = nodes[b]
    nodes[b] = temporary
    positions[Int(nodes[a].connectionIndex)] = a
    positions[Int(nodes[b].connectionIndex)] = b
  }
  private mutating func siftUp(_ start: Int) -> Int {
    var i = start
    while i > 0 {
      let parent = (i - 1) / 2
      if !less(i, parent) { break }
      swap(i, parent)
      i = parent
    }
    return i
  }
  private mutating func siftDown(_ start: Int) {
    var i = start
    while i * 2 + 1 < size {
      var child = i * 2 + 1
      if child + 1 < size && less(child + 1, child) { child += 1 }
      if !less(child, i) { break }
      swap(child, i)
      i = child
    }
  }
  package mutating func insertOrUpdate(connectionIndex: UInt32, deadline: UInt64) -> Bool {
    guard Int(connectionIndex) < capacity else { return false }
    var i = positions[Int(connectionIndex)]
    if i >= 0 {
      let previous = nodes[i].deadline
      if previous == deadline { return true }
      nodes[i].deadline = deadline
      if deadline < previous { _ = siftUp(i) } else { siftDown(i) }
      return true
    }
    if i < 0 {
      guard size < capacity else { return false }
      i = size
      size += 1
      positions[Int(connectionIndex)] = i
    }
    nodes[i] = CESTimerNode(deadline: deadline, connectionIndex: connectionIndex)
    _ = siftUp(i)
    return true
  }
  package mutating func remove(connectionIndex: UInt32) -> Bool {
    guard Int(connectionIndex) < capacity else { return false }
    let i = positions[Int(connectionIndex)]
    guard i >= 0 else { return false }
    positions[Int(connectionIndex)] = -1
    size -= 1
    if i < size {
      nodes[i] = nodes[size]
      positions[Int(nodes[i].connectionIndex)] = i
      let p = siftUp(i)
      siftDown(p)
    }
    return true
  }
  package mutating func popExpired(now: UInt64) -> UInt32? {
    guard size > 0, nodes[0].deadline <= now else { return nil }
    let index = nodes[0].connectionIndex
    _ = remove(connectionIndex: index)
    return index
  }
  package borrowing func waitMilliseconds(now: UInt64) -> UInt32 {
    guard size > 0 else { return UInt32.max }
    return UInt32(
      min(UInt64(UInt32.max - 1), nodes[0].deadline > now ? nodes[0].deadline - now : 0))
  }
}

// Transport records: fixed addresses Windows may borrow. Business state belongs
// exclusively to the pure engine. Provider ownership is retired before Events.
@unsafe
package struct CESEngineRequest {
  package var connectionIndex: UInt32 = 0
  package var operation: CESEngineOperation = .receive
  package init() {}
}
@unsafe
package struct CESEngineConnection {
  package var owner: UnsafeMutablePointer<CESEngineWorker>?
  package var socket: SOCKET = ~SOCKET(0)
  package var requestQueue: RIO_RQ?
  package var buffer = unsafe RIO_BUF()
  package var index: UInt32 = 0
  package var providerOperation: CESEngineOperation?
  package var postedLength: UInt32 = 0
  package init() {}
}
@unsafe
package struct CESUdpSlot {
  package var payload = unsafe RIO_BUF()
  package var remoteAddress = unsafe RIO_BUF()
  package var index: UInt32 = 0
  package var providerOperation: CESEngineOperation?
  package var postedLength: UInt32 = 0
  package init() {}
}
@unsafe
package struct CESAcceptOperation {
  package var overlapped = unsafe OVERLAPPED()
  package var owner: UnsafeMutablePointer<CESEngineAcceptor>?
  package var socket: SOCKET = ~SOCKET(0)
  package var acceptPort: HANDLE?
  package var addressOffset = 0
  package var index: UInt32 = 0
  package var providerOwned = false
  package init() {}
}
package func cesAcceptOverlapped(_ operation: UnsafeMutablePointer<CESAcceptOperation>) -> UnsafeMutablePointer<OVERLAPPED> {
  guard let offset = unsafe MemoryLayout<CESAcceptOperation>.offset(of: \CESAcceptOperation.overlapped) else { cesFailFast(stage: "server accept overlapped layout", error: 13) }
  return unsafe UnsafeMutableRawPointer(operation).advanced(by: offset).assumingMemoryBound(to: OVERLAPPED.self)
}
package func cesAcceptorOperationForAddress(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>, address: UInt) -> UnsafeMutablePointer<CESAcceptOperation>? {
  guard let base = unsafe acceptor.pointee.operationAddress else { return nil }
  let first = UInt(bitPattern: base)
  let stride = unsafe UInt(MemoryLayout<CESAcceptOperation>.stride)
  let (extent, overflow) = stride.multipliedReportingOverflow(by: UInt(unsafe acceptor.pointee.operationCount))
  let (end, endOverflow) = first.addingReportingOverflow(extent)
  guard stride != 0 && !overflow && !endOverflow && address >= first && address < end && (address - first) % stride == 0 else { return nil }
  let index = UInt32((address - first) / stride)
  let operation = unsafe base.advanced(by: Int(index))
  guard unsafe operation.pointee.owner == acceptor, unsafe operation.pointee.index == index else { return nil }
  return unsafe operation
}
package func cesUdpSlotForAddress(slots: UnsafeMutablePointer<CESUdpSlot>, count: Int, address: UInt) -> UnsafeMutablePointer<CESUdpSlot>? {
  guard count > 0 else { return nil }
  let first = UInt(bitPattern: slots), stride = unsafe UInt(MemoryLayout<CESUdpSlot>.stride)
  let (extent, overflow) = stride.multipliedReportingOverflow(by: UInt(count))
  let (end, endOverflow) = first.addingReportingOverflow(extent)
  guard stride != 0 && !overflow && !endOverflow && address >= first && address < end && (address - first) % stride == 0 else { return nil }
  let index = UInt32((address - first) / stride)
  let slot = unsafe slots.advanced(by: Int(index))
  return unsafe slot.pointee.index == index ? slot : nil
}
@unsafe
package struct CESWorkerConfiguration: ~Copyable {
  package let options: CESOptions
  package let rio: RIO_EXTENSION_FUNCTION_TABLE
  private let controlStorage: CESSharedControl
  package var control: CESSharedControl { borrow { unsafe controlStorage } }
  private let failureStorage: CESFailureFlag
  package var failure: CESFailureFlag { borrow { unsafe failureStorage } }
  private let creditsStorage: CESAdmissionCredits
  package var credits: CESAdmissionCredits { borrow { unsafe creditsStorage } }
  package let workerIndex: UInt32
  package let slotCount: UInt32
  package let memoryShare: UInt64
  package init(options: CESOptions, rio: RIO_EXTENSION_FUNCTION_TABLE, control: CESSharedControl, failure: CESFailureFlag, credits: CESAdmissionCredits, workerIndex: UInt32, slotCount: UInt32, memoryShare: UInt64) {
    unsafe self.options = options; unsafe self.rio = rio; unsafe controlStorage = control
    unsafe failureStorage = failure; unsafe creditsStorage = credits
    unsafe self.workerIndex = workerIndex; unsafe self.slotCount = slotCount; unsafe self.memoryShare = memoryShare
  }
}
@unsafe
package struct CESEngineWorker: ~Copyable {
  private let configurationStorage: CESWorkerConfiguration
  package var configuration: CESWorkerConfiguration { borrow { unsafe configurationStorage } }
  private var engineStorage: CESTcpEngine
  package var engine: CESTcpEngine { borrow { unsafe engineStorage } mutate { unsafe &engineStorage } }
  package var thread = CESHandleOwner()
  package var port = CESHandleOwner()
  package var readyEvent = CESHandleOwner()
  fileprivate var arena: CESRioArena?
  fileprivate var completionQueue = CESRIOCQOwner()
  package var connections: CESPinnedStorage<CESEngineConnection>?
  package var requests: CESPinnedStorage<CESEngineRequest>?
  package var notification: CESPinnedStorage<OVERLAPPED>?
  package var results: CESPinnedStorage<RIORESULT>?
  package var connectionAddress: UnsafeMutablePointer<CESEngineConnection>?
  package var requestAddress: UnsafeMutablePointer<CESEngineRequest>?
  package var notificationAddress: UnsafeMutablePointer<OVERLAPPED>?
  package var resultsAddress: UnsafeMutablePointer<RIORESULT>?
  package var requestRange: Range<UInt> = 0..<0
  package var acceptorAddress: UnsafeMutablePointer<CESEngineAcceptor>?
  package var providerOutstanding: UInt32 = 0
  package var notificationArmed = false
  package var snapshot = CESNotifySnapshot()
  package var ready = false
  package var joined = false
  package init(configuration: consuming CESWorkerConfiguration) throws(CESFailure) {
    unsafe engineStorage = try CESTcpEngine(checkedSlotCount: configuration.slotCount, timeoutMilliseconds: UInt64(configuration.options.timeoutSeconds) * 1000)
    unsafe configurationStorage = consume configuration
  }
  deinit {
    unsafe cesRequireRelease(providerOutstanding: providerOutstanding, businessOutstanding: engineStorage.outstanding, stage: "worker RIO cleanup with outstanding operations")
    if unsafe thread.rawValue != nil && !joined { cesFailFast(stage: "server worker release before join", error: 5023) }
    if let connections = unsafe connectionAddress {
      for i in unsafe 0..<Int(configurationStorage.slotCount) { if unsafe connections[i].providerOperation != nil { cesFailFast(stage: "worker RIO cleanup with outstanding operations", error: 996) } }
    }
    if unsafe port.rawValue != nil || completionQueue.rawValue != nil { cesFailFast(stage: "server worker requires explicit resource teardown", error: 5023) }
  }
}

// RioTransport: native posts return a complete error, never a hidden state change.
private func cesWorkerCloseSlot(_ w: UnsafeMutablePointer<CESEngineWorker>, index: UInt32) {
  let c = unsafe w.pointee.connectionAddress!.advanced(by: Int(index))
  if unsafe c.pointee.socket != ~SOCKET(0) { unsafe closesocket(c.pointee.socket); unsafe c.pointee.socket = ~SOCKET(0) }
  unsafe c.pointee.requestQueue = nil
}
package func cesWorkerReleaseSlot(_ w: UnsafeMutablePointer<CESEngineWorker>, index: UInt32) {
  guard unsafe index < w.pointee.configuration.slotCount, let base = unsafe w.pointee.connectionAddress else { cesFailFast(stage: "TCP connection release index", error: 13) }
  let c = unsafe base.advanced(by: Int(index))
  guard unsafe c.pointee.providerOperation == nil else { cesFailFast(stage: "TCP connection release precondition", error: 996) }
  unsafe cesWorkerCloseSlot(w, index: index)
  unsafe w.pointee.configuration.credits.release()
}
private func cesWorkerPost(_ w: UnsafeMutablePointer<CESEngineWorker>, index: UInt32, operation: CESEngineOperation, offset: UInt32, length: UInt32) -> CESFailure? {
  guard unsafe index < w.pointee.configuration.slotCount else { cesFailFast(stage: "worker post index", error: 13) }
  let c = unsafe w.pointee.connectionAddress!.advanced(by: Int(index))
  guard unsafe c.pointee.providerOperation == nil, let rq = unsafe c.pointee.requestQueue else { cesFailFast(stage: "worker post ownership", error: 13) }
  let stride = unsafe w.pointee.configuration.options.rioBufferBytes
  guard offset <= stride && length <= stride - offset && (operation == .receive || length != 0) else { cesFailFast(stage: "server send registration extent", error: 13) }
  guard unsafe w.pointee.arena != nil else { cesFailFast(stage: "worker missing arena", error: 13) }
  unsafe c.pointee.buffer = unsafe w.pointee.arena!.view(index: index, offset: offset, length: length)
  let request = unsafe w.pointee.requestAddress!.advanced(by: Int(index))
  unsafe request.pointee.operation = operation
  let bufferOffset = unsafe MemoryLayout<CESEngineConnection>.offset(of: \CESEngineConnection.buffer)!
  let buffer = unsafe UnsafeMutableRawPointer(c).advanced(by: bufferOffset).assumingMemoryBound(to: RIO_BUF.self)
  let rio = unsafe w.pointee.configuration.rio
  let succeeded = operation == .receive
    ? unsafe rio.RIOReceive!(rq, buffer, 1, 0, request).boolValue
    : unsafe rio.RIOSend!(rq, buffer, 1, 0, request).boolValue
  if !succeeded { return cesWinsockFailure(operation == .receive ? "RIOReceive" : "RIOSend") }
  unsafe c.pointee.providerOperation = operation; unsafe c.pointee.postedLength = length
  unsafe w.pointee.providerOutstanding += 1
  unsafe w.pointee.arena!.didPost()
  return nil
}
private func cesWorkerExecute(_ w: UnsafeMutablePointer<CESEngineWorker>, _ action: CESAction?) {
  if let failure = unsafe w.pointee.engine.failure, failure.classification != .network { cesFailFast(stage: failure.stage, error: failure.code) }
  guard let action else { return }
  let failure: CESFailure?
  switch action {
  case .close(let index): unsafe cesWorkerCloseSlot(w, index: index); return
  case .release(let index):
    guard unsafe w.pointee.engine.connection(index)?.outstanding == 0 else { cesFailFast(stage: "TCP business release precondition", error: 996) }
    unsafe cesWorkerReleaseSlot(w, index: index); return
  case .receive(let index, _): failure = unsafe cesWorkerPost(w, index: index, operation: .receive, offset: 0, length: w.pointee.configuration.options.rioBufferBytes)
  case .send(let index, let offset, let length, _): failure = unsafe cesWorkerPost(w, index: index, operation: .send, offset: offset, length: length)
  }
  if let failure {
    cesReport(stage: failure.stage, error: failure.code)
    let next = unsafe w.pointee.engine.onEvent(.postFailed(index: action.index, failure: failure), now: GetTickCount64())
    unsafe cesWorkerExecute(w, next)
  }
}
private func cesWorkerArm(_ w: UnsafeMutablePointer<CESEngineWorker>) {
  guard unsafe w.pointee.providerOutstanding != 0 && !w.pointee.notificationArmed else { return }
  unsafe w.pointee.notificationAddress!.pointee = OVERLAPPED()
  cesRequireRIONotifySuccess(unsafe w.pointee.configuration.rio.RIONotify!(w.pointee.completionQueue.rawValue), stage: "RIONotify(worker)")
  unsafe w.pointee.notificationArmed = true; unsafe w.pointee.snapshot.arms &+= 1
}
package func cesWorkerNormalizeCompletion(_ w: UnsafeMutablePointer<CESEngineWorker>, result: RIORESULT) -> CESCompletion {
  guard let requests = unsafe w.pointee.requestAddress, let connections = unsafe w.pointee.connectionAddress else { cesFailFast(stage: "server RIO RequestContext range", error: 13) }
  let address = UInt(result.RequestContext)
  let first = UInt(bitPattern: requests)
  let stride = unsafe UInt(MemoryLayout<CESEngineRequest>.stride)
  guard unsafe w.pointee.requestRange.contains(address), stride != 0, (address - first) % stride == 0 else { cesFailFast(stage: "server RIO RequestContext range", error: 13) }
  let index = UInt32((address - first) / stride)
  let c = unsafe connections.advanced(by: Int(index))
  let request = unsafe requests.advanced(by: Int(index))
  guard unsafe c.pointee.owner == w, unsafe c.pointee.index == index, unsafe request.pointee.connectionIndex == index else { cesFailFast(stage: "server RIO request metadata", error: 13) }
  guard let operation = unsafe c.pointee.providerOperation, unsafe operation == request.pointee.operation, unsafe w.pointee.providerOutstanding != 0 else { cesFailFast(stage: "worker completion without provider ownership", error: 13) }
  guard unsafe result.BytesTransferred <= c.pointee.postedLength else { cesFailFast(stage: "worker completion exceeds posted range", error: 13) }
  return CESCompletion(index: index, operation: operation, status: result.Status, bytes: result.BytesTransferred)
}
private func cesWorkerDrain(_ w: UnsafeMutablePointer<CESEngineWorker>, batches: Int = 64, recordBudget: UInt32? = nil, yieldOnStop: Bool = true) {
  var remaining = recordBudget
  for _ in 0..<batches {
    let capacity = min(UInt32(CESConstants.completionBatchSize), remaining ?? UInt32(CESConstants.completionBatchSize))
    if capacity == 0 { return }
    let count = unsafe cesRequireValidDequeueCount(w.pointee.configuration.rio.RIODequeueCompletion!(w.pointee.completionQueue.rawValue, w.pointee.resultsAddress, capacity), stage: "RIODequeueCompletion(worker)")
    guard count <= capacity else { cesFailFast(stage: "server dequeue batch", error: 13) }
    if count == 0 { return }
    if remaining != nil { remaining! -= count }
    for i in 0..<Int(count) {
      let result = unsafe w.pointee.resultsAddress![i]
      let value = unsafe cesWorkerNormalizeCompletion(w, result: result)
      let index = value.index
      let c = unsafe w.pointee.connectionAddress!.advanced(by: Int(index))
      unsafe c.pointee.providerOperation = nil; unsafe c.pointee.postedLength = 0; unsafe w.pointee.providerOutstanding -= 1
      unsafe w.pointee.arena!.didComplete()
      let action = unsafe w.pointee.engine.onEvent(.completion(value), now: GetTickCount64())
      unsafe cesWorkerExecute(w, action)
    }
    if yieldOnStop && unsafe w.pointee.configuration.control.stopRequested.load(ordering: .acquiring) { return }
  }
}
private func cesWorkerStop(_ w: UnsafeMutablePointer<CESEngineWorker>) {
  if unsafe w.pointee.engine.stopping { return }
  let now = GetTickCount64()
  for i in unsafe 0..<w.pointee.configuration.slotCount {
    let action = unsafe w.pointee.engine.beginStop(index: i, now: now)
    unsafe cesWorkerExecute(w, action)
  }
}
package func cesAckAccept(_ operation: UnsafeMutablePointer<CESAcceptOperation>) {
  let succeeded = unsafe PostQueuedCompletionStatus(operation.pointee.acceptPort, 0, UInt64(UInt(bitPattern: operation)), nil)
  if !succeeded { cesFailFast(stage: "PostQueuedCompletionStatus(accept ack)", error: Int32(bitPattern: GetLastError())) }
}
private func cesWorkerTakeSocket(_ w: UnsafeMutablePointer<CESEngineWorker>, operation: UnsafeMutablePointer<CESAcceptOperation>) {
  let raw = unsafe operation.pointee.socket
  unsafe operation.pointee.socket = ~SOCKET(0)
  var owner = CESSocketOwner(raw)
  if unsafe w.pointee.engine.stopping {
    owner.reset(); unsafe w.pointee.configuration.credits.release(); unsafe cesAckAccept(operation); return
  }
  guard raw != ~SOCKET(0) else { cesFailFast(stage: "server accept handoff socket", error: 13) }
  guard let index = unsafe w.pointee.engine.takeSlot() else { cesFailFast(stage: "admission credit/free pool mismatch", error: 5023) }
  let c = unsafe w.pointee.connectionAddress!.advanced(by: Int(index))
  let rio = unsafe w.pointee.configuration.rio
  guard let rq = unsafe rio.RIOCreateRequestQueue!(raw, 1, 1, 1, 1, w.pointee.completionQueue.rawValue, w.pointee.completionQueue.rawValue, c) else {
    let error = WSAGetLastError(); cesReport(stage: "RIOCreateRequestQueue(TCP)", error: error)
    unsafe w.pointee.engine.statistics.networkErrors &+= 1; unsafe w.pointee.engine.returnSlot(index)
    owner.reset(); unsafe w.pointee.configuration.credits.release(); unsafe cesAckAccept(operation); return
  }
  unsafe c.pointee.socket = owner.release(); unsafe c.pointee.requestQueue = rq
  let action = unsafe w.pointee.engine.admit(index: index, now: GetTickCount64())
  unsafe cesWorkerExecute(w, action); unsafe cesAckAccept(operation)
}
private func cesWorkerPacket(_ w: UnsafeMutablePointer<CESEngineWorker>, wait: UInt32) -> Bool {
  var transferred: DWORD = 0; var key: UInt64 = 0; var overlap: UnsafeMutablePointer<OVERLAPPED>?
  let ok = unsafe GetQueuedCompletionStatus(w.pointee.port.rawValue, &transferred, &key, &overlap, wait)
  let error = ok ? 0 : GetLastError()
  if unsafe overlap == w.pointee.notificationAddress {
    if !ok { cesFailFast(stage: "GetQueuedCompletionStatus(worker notification)", error: Int32(bitPattern: error)) }
    unsafe cesRequireNotificationPacket(key: UInt(key), overlapped: overlap, expectedKey: UInt(bitPattern: w), expectedOverlapped: w.pointee.notificationAddress, stage: "server worker RIO notification key")
    if unsafe !cesNotificationMarkDelivered(&w.pointee.notificationArmed) { cesFailFast(stage: "server worker notification delivery transition", error: 5023) }
    unsafe w.pointee.snapshot.deliveries &+= 1; unsafe cesWorkerDrain(w)
  } else if unsafe overlap == nil && key == CESConstants.stopKey { unsafe cesWorkerStop(w) }
  else if unsafe overlap == nil && key == CESConstants.admissionClosedKey { _ = unsafe w.pointee.engine.onEvent(.admissionClosed, now: GetTickCount64()) }
  else if unsafe overlap == nil && key > CESConstants.admissionClosedKey {
    guard let acceptor = unsafe w.pointee.acceptorAddress, let operation = unsafe cesAcceptorOperationForAddress(acceptor, address: UInt(key)) else { cesFailFast(stage: "server accept handoff identity", error: 13) }
    unsafe cesWorkerTakeSocket(w, operation: operation)
  } else if !ok && error == WAIT_TIMEOUT && unsafe overlap == nil {
    if unsafe !w.pointee.engine.stopping && w.pointee.providerOutstanding != 0 && !w.pointee.notificationArmed { unsafe w.pointee.snapshot.timeoutWakeups &+= 1 }
    return false
  }
  else if !ok {
    cesReport(stage: "GetQueuedCompletionStatus(worker)", error: Int32(bitPattern: error))
    unsafe w.pointee.engine.statistics.networkErrors &+= 1
    unsafe w.pointee.configuration.failure.failed.store(true, ordering: .releasing); unsafe cesWorkerStop(w)
  } else { cesFailFast(stage: "unexpected worker IOCP packet", error: 13) }
  return true
}
@c
package func cesWorkerThread(_ parameter: UnsafeMutableRawPointer?) -> DWORD {
  let w = unsafe parameter!.assumingMemoryBound(to: CESEngineWorker.self)
  unsafe w.pointee.engine.phase = .running; unsafe w.pointee.ready = true
  if unsafe !SetEvent(w.pointee.readyEvent.rawValue) { cesFailFast(stage: "SetEvent(worker ready)", error: Int32(bitPattern: GetLastError())) }
  while true {
    unsafe cesWorkerArm(w)
    let wait = unsafe w.pointee.engine.timers.waitMilliseconds(now: GetTickCount64())
    var budget = unsafe Int(w.pointee.configuration.slotCount + cesAcceptOperationCount(CESConstants.maximumWorkers) + 2)
    var packetWait = wait
    while true {
      let delivered = unsafe cesWorkerPacket(w, wait: packetWait)
      if packetWait != 0 && unsafe w.pointee.engine.timers.waitMilliseconds(now: GetTickCount64()) == 0 {
        budget = unsafe Int(w.pointee.configuration.slotCount + cesAcceptOperationCount(CESConstants.maximumWorkers) + 2)
      } else { budget -= 1 }
      if (!delivered && packetWait == 0) || budget == 0 || (wait != 0 && unsafe w.pointee.engine.timers.waitMilliseconds(now: GetTickCount64()) != 0) { break }
      packetWait = 0; unsafe cesWorkerArm(w)
    }
    let now = GetTickCount64()
    if unsafe w.pointee.engine.timers.waitMilliseconds(now: now) == 0 {
      unsafe cesWorkerDrain(w, batches: Int(w.pointee.configuration.slotCount), recordBudget: w.pointee.configuration.slotCount, yieldOnStop: false)
    }
    while let index = unsafe w.pointee.engine.timers.popExpired(now: now) {
      let action = unsafe w.pointee.engine.onTimeout(index: index, now: now)
      unsafe cesWorkerExecute(w, action)
    }
    if unsafe w.pointee.engine.stopping && w.pointee.engine.admissionClosed && w.pointee.engine.activeCount == 0 { break }
  }
  unsafe w.pointee.engine.phase = .stopped
  return 0
}
package func cesInitializeWorker(_ w: UnsafeMutablePointer<CESEngineWorker>) -> CESFailure? {
  unsafe w.pointee.port.reset(CreateIoCompletionPort(HANDLE(bitPattern: -1), nil, 0, 1))
  guard unsafe w.pointee.port.rawValue != nil else { return cesWin32Failure("CreateIoCompletionPort(worker)") }
  unsafe w.pointee.readyEvent.reset(CreateEventW(nil, true, false, nil))
  guard unsafe w.pointee.readyEvent.rawValue != nil else { return cesWin32Failure("CreateEventW(worker ready)") }
  let count = unsafe Int(w.pointee.configuration.slotCount)
  guard let connections = unsafe CESPinnedStorage(count: count, initialValue: CESEngineConnection()), let requests = unsafe CESPinnedStorage(count: count, initialValue: CESEngineRequest()), let notification = unsafe CESPinnedStorage(count: 1, initialValue: OVERLAPPED()), let results = unsafe CESPinnedStorage(count: CESConstants.completionBatchSize, initialValue: RIORESULT()) else { return .allocation("worker allocation") }
  unsafe w.pointee.connectionAddress = connections.baseAddress; unsafe w.pointee.requestAddress = requests.baseAddress
  unsafe w.pointee.notificationAddress = notification.baseAddress; unsafe w.pointee.resultsAddress = results.baseAddress
  unsafe w.pointee.connections = consume connections; unsafe w.pointee.requests = consume requests
  unsafe w.pointee.notification = consume notification; unsafe w.pointee.results = consume results
  do { unsafe w.pointee.arena = unsafe try CESRioArena(rio: w.pointee.configuration.rio, slots: w.pointee.configuration.slotCount, stride: w.pointee.configuration.options.rioBufferBytes, memoryLimit: w.pointee.configuration.memoryShare) }
  catch { return error }
  let first = unsafe UInt(bitPattern: w.pointee.requestAddress!)
  let (extent, overflow) = unsafe UInt(MemoryLayout<CESEngineRequest>.stride).multipliedReportingOverflow(by: UInt(count))
  let (end, endOverflow) = first.addingReportingOverflow(extent)
  guard !overflow && !endOverflow else { return .invariant("server request allocation extent") }
  unsafe w.pointee.requestRange = first..<end
  for i in 0..<count {
    unsafe w.pointee.connectionAddress![i].owner = w; unsafe w.pointee.connectionAddress![i].index = UInt32(i)
    unsafe w.pointee.requestAddress![i].connectionIndex = UInt32(i)
  }
  var notificationDescription = unsafe RIO_NOTIFICATION_COMPLETION()
  unsafe notificationDescription.Type = RIO_IOCP_COMPLETION
  unsafe notificationDescription.Iocp.IocpHandle = w.pointee.port.rawValue
  unsafe notificationDescription.Iocp.CompletionKey = UnsafeMutableRawPointer(w)
  unsafe notificationDescription.Iocp.Overlapped = UnsafeMutableRawPointer(w.pointee.notificationAddress!)
  guard let queue = unsafe w.pointee.configuration.rio.RIOCreateCompletionQueue!(w.pointee.configuration.slotCount * 2, &notificationDescription) else { return cesWinsockFailure("RIOCreateCompletionQueue(worker)") }
  unsafe w.pointee.completionQueue.reset(rio: w.pointee.configuration.rio, value: queue)
  return nil
}
package func cesStartWorker(_ w: UnsafeMutablePointer<CESEngineWorker>) -> CESFailure? {
  unsafe w.pointee.thread.reset(CreateThread(nil, 0, cesWorkerThread, w, 0, nil))
  guard unsafe w.pointee.thread.rawValue != nil else { return cesWin32Failure("CreateThread(worker)") }
  guard unsafe WaitForSingleObject(w.pointee.readyEvent.rawValue, UInt32.max) == WAIT_OBJECT_0, unsafe w.pointee.ready else { return .invariant("worker startup readiness") }
  return nil
}
private func cesWorkerControlPost(_ w: UnsafeMutablePointer<CESEngineWorker>, key: UInt, stage: String) {
  let ok = unsafe PostQueuedCompletionStatus(w.pointee.port.rawValue, 0, UInt64(key), nil)
  if !ok { cesFailFast(stage: stage, error: Int32(bitPattern: GetLastError())) }
}
package func cesPostWorkerStop(_ w: UnsafeMutablePointer<CESEngineWorker>) { unsafe cesWorkerControlPost(w, key: CESConstants.stopKey, stage: "PostQueuedCompletionStatus(worker stop)") }
package func cesPostWorkerAdmissionClosed(_ w: UnsafeMutablePointer<CESEngineWorker>) { unsafe cesWorkerControlPost(w, key: CESConstants.admissionClosedKey, stage: "PostQueuedCompletionStatus(worker admission closed)") }
package func cesJoinWorker(_ w: UnsafeMutablePointer<CESEngineWorker>) {
  if let thread = unsafe w.pointee.thread.rawValue {
    if unsafe WaitForSingleObject(thread, UInt32.max) != WAIT_OBJECT_0 { cesFailFast(stage: "server worker join", error: Int32(bitPattern: GetLastError())) }
  }
  unsafe w.pointee.joined = true
}
package func cesRequireWorkerRelease(_ w: UnsafeMutablePointer<CESEngineWorker>) {
  cesRequireRelease(providerOutstanding: unsafe w.pointee.providerOutstanding, businessOutstanding: unsafe w.pointee.engine.outstanding, stage: "worker RIO cleanup with outstanding operations")
  if let connections = unsafe w.pointee.connectionAddress {
    for i in unsafe 0..<Int(w.pointee.configuration.slotCount) { if unsafe connections[i].providerOperation != nil { cesFailFast(stage: "worker RIO cleanup with outstanding operations", error: 996) } }
  }
  if unsafe w.pointee.thread.rawValue != nil && !w.pointee.joined { cesFailFast(stage: "server worker release before join", error: 5023) }
  if unsafe w.pointee.thread.rawValue != nil && (!w.pointee.engine.mayExit || w.pointee.engine.freeCount != w.pointee.configuration.slotCount || !w.pointee.configuration.credits.isFull) { cesFailFast(stage: "server worker release precondition", error: 5023) }
  if unsafe !w.pointee.snapshot.valid { cesFailFast(stage: "server worker notification accounting", error: 5023) }
}
package func cesDestroyWorker(_ w: UnsafeMutablePointer<CESEngineWorker>) {
  unsafe cesRequireWorkerRelease(w)
  unsafe w.pointee.thread.reset(); unsafe w.pointee.completionQueue.reset()
  unsafe w.pointee.arena?.release(providerOutstanding: w.pointee.providerOutstanding, businessOutstanding: w.pointee.engine.outstanding)
  unsafe w.pointee.arena = nil
  if unsafe w.pointee.connectionAddress != nil { for i in unsafe 0..<w.pointee.configuration.slotCount { unsafe cesWorkerCloseSlot(w, index: i) } }
  unsafe w.pointee.readyEvent.reset(); unsafe w.pointee.port.reset()
  // Real notification/key/context addresses remain alive until CQ and IOCP close.
  unsafe w.pointee.results = nil; unsafe w.pointee.requests = nil; unsafe w.pointee.connections = nil; unsafe w.pointee.notification = nil
  unsafe w.pointee.connectionAddress = nil; unsafe w.pointee.requestAddress = nil; unsafe w.pointee.notificationAddress = nil; unsafe w.pointee.resultsAddress = nil
}

@unsafe
package struct CESAcceptorConfiguration: ~Copyable {
  package let options: CESOptions
  private let controlStorage: CESSharedControl
  package var control: CESSharedControl { borrow { unsafe controlStorage } }
  private let failureStorage: CESFailureFlag
  package var failure: CESFailureFlag { borrow { unsafe failureStorage } }
  package let workers: UnsafeMutablePointer<CESEngineWorker>
  package let workerCount: UInt32
  package init(options: CESOptions, control: CESSharedControl, failure: CESFailureFlag, workers: UnsafeMutablePointer<CESEngineWorker>, workerCount: UInt32) {
    unsafe self.options = options; unsafe controlStorage = control; unsafe failureStorage = failure
    unsafe self.workers = workers; unsafe self.workerCount = workerCount
  }
}
@unsafe
package struct CESEngineAcceptor: ~Copyable {
  private let configurationStorage: CESAcceptorConfiguration
  package var configuration: CESAcceptorConfiguration { borrow { unsafe configurationStorage } }
  private var coreStorage: CESAcceptorCore
  package var core: CESAcceptorCore { borrow { unsafe coreStorage } mutate { unsafe &coreStorage } }
  package var listener = CESSocketOwner()
  package var port = CESHandleOwner()
  package var readyEvent = CESHandleOwner()
  package var thread = CESHandleOwner()
  package var operations: CESPinnedStorage<CESAcceptOperation>?
  package var addresses: CESPinnedStorage<UInt8>?
  package var operationAddress: UnsafeMutablePointer<CESAcceptOperation>?
  package var addressBuffer: UnsafeMutablePointer<UInt8>?
  package let operationCount: UInt32
  package var acceptEx: LPFN_ACCEPTEX?
  package var acceptAddresses: LPFN_GETACCEPTEXSOCKADDRS?
  package var drainDeadline: UInt64?
  package var ready = false
  package var startupOK = true
  package var joined = false
  package init(configuration: consuming CESAcceptorConfiguration) throws(CESFailure) {
    unsafe operationCount = cesAcceptOperationCount(configuration.workerCount)
    unsafe coreStorage = try CESAcceptorCore(count: operationCount, workers: configuration.workerCount)
    for index in unsafe 0..<configuration.workerCount {
      unsafe coreStorage.assignCredit(index: index, credit: configuration.workers[Int(index)].configuration.credits)
    }
    unsafe configurationStorage = consume configuration
  }
  deinit {
    if unsafe coreStorage.liveCount != 0 { cesFailFast(stage: "server acceptor release precondition", error: 996) }
    if unsafe thread.rawValue != nil && !joined { cesFailFast(stage: "server acceptor release before join", error: 5023) }
    if let operations = unsafe operationAddress { for i in unsafe 0..<Int(operationCount) { if unsafe operations[i].providerOwned { cesFailFast(stage: "server acceptor release precondition", error: 996) } } }
    if unsafe port.rawValue != nil { cesFailFast(stage: "server acceptor requires explicit resource teardown", error: 5023) }
  }
}
private func cesCloseAcceptSocket(_ operation: UnsafeMutablePointer<CESAcceptOperation>) {
  if unsafe operation.pointee.socket != ~SOCKET(0) { unsafe closesocket(operation.pointee.socket); unsafe operation.pointee.socket = ~SOCKET(0) }
}
private func cesAcceptorStop(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) {
  if unsafe acceptor.pointee.core.stopping { return }
  _ = unsafe acceptor.pointee.core.onEvent(.stop)
  unsafe acceptor.pointee.drainDeadline = cesSaturatingAdd(GetTickCount64(), CESConstants.drainGraceMilliseconds)
  unsafe acceptor.pointee.listener.reset()
  if let operations = unsafe acceptor.pointee.operationAddress {
    for i in unsafe 0..<Int(acceptor.pointee.operationCount) {
      if unsafe operations[i].providerOwned { unsafe cesCloseAcceptSocket(operations.advanced(by: i)) }
    }
  }
}
private func cesAcceptorFail(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>, failure: CESFailure, report: Bool = true) {
  if failure.classification != .network { cesFailFast(stage: failure.stage, error: failure.code) }
  if report { cesReport(stage: failure.stage, error: failure.code) }
  unsafe acceptor.pointee.configuration.failure.failed.store(true, ordering: .releasing)
  unsafe cesAcceptorStop(acceptor)
}
private func cesPostAccept(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>, index: UInt32) -> Bool {
  let operation = unsafe acceptor.pointee.operationAddress!.advanced(by: Int(index))
  for _ in 0..<CESConstants.inlineAcceptRetries {
    if unsafe acceptor.pointee.core.stopping || acceptor.pointee.configuration.failure.failed.load(ordering: .acquiring) { return true }
    guard unsafe !operation.pointee.providerOwned, unsafe acceptor.pointee.core.states[Int(index)] == .idle else { cesFailFast(stage: "AcceptEx post ownership", error: 13) }
    unsafe cesAcceptOverlapped(operation).pointee = OVERLAPPED()
    let raw = cesRegisteredSocket(transport: .tcp)
    if raw == ~SOCKET(0) {
      let f = cesWinsockFailure("WSASocketW(accepted RIO socket)")
      unsafe acceptor.pointee.core.statistics.networkErrors &+= 1
      unsafe cesAcceptorFail(acceptor, failure: f); return false
    }
    unsafe operation.pointee.socket = raw
    let buffer = unsafe acceptor.pointee.addressBuffer!.advanced(by: operation.pointee.addressOffset)
    var received: DWORD = 0
    if unsafe !acceptor.pointee.core.markPosted(index: index) { cesFailFast(stage: "AcceptEx post ownership", error: 13) }
    let ok = unsafe acceptor.pointee.acceptEx!(acceptor.pointee.listener.rawValue, raw, buffer, 0, DWORD(CESConstants.acceptAddressBytes), DWORD(CESConstants.acceptAddressBytes), &received, cesAcceptOverlapped(operation))
    let error = ok.boolValue ? 0 : WSAGetLastError()
    if ok.boolValue || error == 997 { unsafe operation.pointee.providerOwned = true; return true }
    unsafe acceptor.pointee.core.returnSlot(index: index)
    unsafe cesCloseAcceptSocket(operation)
    unsafe acceptor.pointee.core.statistics.networkErrors &+= 1
    if !cesAcceptErrorIsRecoverable(UInt32(bitPattern: error)) { unsafe cesAcceptorFail(acceptor, failure: CESFailure(stage: "AcceptEx", code: error)); return false }
  }
  // A synchronous reset burst yields to one queued repost control packet.
  unsafe acceptor.pointee.core.deferRepost(index: index)
  let ok = unsafe PostQueuedCompletionStatus(acceptor.pointee.port.rawValue, 0, UInt64(UInt(bitPattern: operation)), nil)
  if !ok { cesFailFast(stage: "PostQueuedCompletionStatus(accept repost)", error: Int32(bitPattern: GetLastError())) }
  return true
}
private func cesAcceptorHandoff(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>, operation: UnsafeMutablePointer<CESAcceptOperation>, candidate: UInt32) {
  let index = unsafe operation.pointee.index
  if unsafe acceptor.pointee.core.stopping || acceptor.pointee.configuration.failure.failed.load(ordering: .acquiring) || acceptor.pointee.listener.rawValue == ~SOCKET(0) || operation.pointee.socket == ~SOCKET(0) {
    unsafe acceptor.pointee.core.states[Int(index)] = .idle; unsafe cesCloseAcceptSocket(operation); return
  }
  var listener = unsafe acceptor.pointee.listener.rawValue
  let updated = withUnsafePointer(to: &listener) { unsafe setsockopt(operation.pointee.socket, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self), Int32(MemoryLayout<SOCKET>.size)) }
  if updated != 0 {
    let failure = cesWinsockFailure("SO_UPDATE_ACCEPT_CONTEXT")
    unsafe acceptor.pointee.core.statistics.networkErrors &+= 1
    unsafe acceptor.pointee.core.states[Int(index)] = .idle; unsafe cesCloseAcceptSocket(operation)
    unsafe cesAcceptorFail(acceptor, failure: failure, report: false); return
  }
  if let failure = unsafe cesConfigureSocketFailure(operation.pointee.socket, options: acceptor.pointee.configuration.options, tcp: true) {
    unsafe acceptor.pointee.core.statistics.networkErrors &+= 1
    unsafe acceptor.pointee.core.states[Int(index)] = .idle; unsafe cesCloseAcceptSocket(operation)
    unsafe cesAcceptorFail(acceptor, failure: failure); return
  }
  var local: UnsafeMutablePointer<SOCKADDR>?; var remote: UnsafeMutablePointer<SOCKADDR>?
  var localLength: Int32 = 0; var remoteLength: Int32 = 0
  let buffer = unsafe acceptor.pointee.addressBuffer!.advanced(by: operation.pointee.addressOffset)
  unsafe acceptor.pointee.acceptAddresses!(buffer, 0, DWORD(CESConstants.acceptAddressBytes), DWORD(CESConstants.acceptAddressBytes), &local, &localLength, &remote, &remoteLength)
  let base = UInt(bitPattern: buffer)
  func validAddress(_ address: UnsafeMutablePointer<SOCKADDR>?, length: Int32) -> Bool {
    guard let address = unsafe address, length >= Int32(MemoryLayout<SOCKADDR_IN>.size), length <= Int32(MemoryLayout<SOCKADDR_STORAGE>.size) else { return false }
    let value = UInt(bitPattern: address)
    guard value >= base, value - base <= UInt(CESConstants.acceptBufferBytes), UInt(length) <= UInt(CESConstants.acceptBufferBytes) - (value - base) else { return false }
    return unsafe address.pointee.sa_family == UInt16(AF_INET)
  }
  guard unsafe validAddress(local, length: localLength), unsafe validAddress(remote, length: remoteLength) else {
    unsafe acceptor.pointee.core.states[Int(index)] = .idle; unsafe cesCloseAcceptSocket(operation)
    unsafe cesAcceptorFail(acceptor, failure: CESFailure(stage: "GetAcceptExSockaddrs", code: 10022)); return
  }
  guard let workerIndex = unsafe acceptor.pointee.core.reserveWorker(candidate: candidate) else {
    unsafe acceptor.pointee.core.states[Int(index)] = .idle; unsafe cesCloseAcceptSocket(operation)
    unsafe acceptor.pointee.core.statistics.rejected &+= 1; _ = unsafe cesPostAccept(acceptor, index: index); return
  }
  let worker = unsafe acceptor.pointee.configuration.workers.advanced(by: Int(workerIndex))
  // Win32 handoff/ack packets publish and relinquish exclusive socket ownership.
  // Acceptor never touches a transit socket until the worker's acknowledgement.
  let ok = unsafe PostQueuedCompletionStatus(worker.pointee.port.rawValue, 0, UInt64(UInt(bitPattern: operation)), nil)
  if !ok { cesFailFast(stage: "PostQueuedCompletionStatus(accept handoff)", error: Int32(bitPattern: GetLastError())) }
}
private func cesAcceptorPacket(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>, wait: UInt32) -> Bool {
  var transferred: DWORD = 0; var key: UInt64 = 0; var overlap: UnsafeMutablePointer<OVERLAPPED>?
  let ok = unsafe GetQueuedCompletionStatus(acceptor.pointee.port.rawValue, &transferred, &key, &overlap, wait)
  let error = ok ? 0 : GetLastError()
  if unsafe overlap == nil && key == CESConstants.stopKey { unsafe cesAcceptorStop(acceptor); return true }
  if unsafe overlap == nil && key > CESConstants.stopKey {
    guard let operation = unsafe cesAcceptorOperationForAddress(acceptor, address: UInt(key)) else { cesFailFast(stage: "server accept acknowledgement identity", error: 13) }
    guard unsafe !operation.pointee.providerOwned else { cesFailFast(stage: "accept ack provider ownership", error: 13) }
    unsafe cesCloseAcceptSocket(operation)
    let action = unsafe acceptor.pointee.core.onEvent(.acknowledged(index: operation.pointee.index))
    switch action { case .repost: _ = unsafe cesPostAccept(acceptor, index: operation.pointee.index)
    case .drop: break
    case .fatal(let failure): cesFailFast(stage: failure.stage, error: failure.code)
    case .handoff: cesFailFast(stage: "accept acknowledgement action", error: 13) }
    return true
  }
  if let overlap = unsafe overlap {
    guard let offset = unsafe MemoryLayout<CESAcceptOperation>.offset(of: \CESAcceptOperation.overlapped) else { cesFailFast(stage: "server accept overlapped layout", error: 13) }
    let address = UInt(bitPattern: overlap)
    guard address >= UInt(offset), let operation = unsafe cesAcceptorOperationForAddress(acceptor, address: address - UInt(offset)), unsafe cesAcceptOverlapped(operation) == overlap,
      unsafe operation.pointee.providerOwned else { cesFailFast(stage: "server AcceptEx completion ownership/range", error: 13) }
    unsafe operation.pointee.providerOwned = false
    let action = unsafe acceptor.pointee.core.onEvent(.completion(index: operation.pointee.index, succeeded: ok, code: error, admissionFailed: acceptor.pointee.configuration.failure.failed.load(ordering: .acquiring)))
    switch action {
    case .handoff(_, let candidate): unsafe cesAcceptorHandoff(acceptor, operation: operation, candidate: candidate)
    case .repost: unsafe cesCloseAcceptSocket(operation); _ = unsafe cesPostAccept(acceptor, index: operation.pointee.index)
    case .drop: unsafe cesCloseAcceptSocket(operation)
    case .fatal(let failure): unsafe cesCloseAcceptSocket(operation); unsafe cesAcceptorFail(acceptor, failure: failure)
    }
    return true
  }
  if !ok && error == WAIT_TIMEOUT { return false }
  if !ok { unsafe cesAcceptorFail(acceptor, failure: CESFailure(domain: .win32, stage: "GetQueuedCompletionStatus(acceptor)", code: Int32(bitPattern: error))); return true }
  cesFailFast(stage: "unexpected acceptor IOCP packet", error: 13)
}
@c
package func cesAcceptorThread(_ parameter: UnsafeMutableRawPointer?) -> DWORD {
  let acceptor = unsafe parameter!.assumingMemoryBound(to: CESEngineAcceptor.self)
  for i in unsafe 0..<acceptor.pointee.operationCount {
    if unsafe !cesPostAccept(acceptor, index: i) { unsafe acceptor.pointee.startupOK = false; break }
  }
  unsafe acceptor.pointee.ready = true
  if unsafe !SetEvent(acceptor.pointee.readyEvent.rawValue) { cesFailFast(stage: "SetEvent(acceptor ready)", error: Int32(bitPattern: GetLastError())) }
  var overdueBudget: UInt32?
  while unsafe !acceptor.pointee.core.stopping || acceptor.pointee.core.liveCount != 0 {
    let now = GetTickCount64()
    let deadline = unsafe acceptor.pointee.drainDeadline
    let due = deadline.map { now >= $0 } ?? false
    if due {
      if overdueBudget == nil { overdueBudget = unsafe acceptor.pointee.operationCount + 1 }
      if overdueBudget == 0 { cesFailFast(stage: "server acceptor drain", error: 1460) }
      overdueBudget! -= 1
    }
    let wait = deadline.map { UInt32(min($0 > now ? $0 - now : 0, 100)) } ?? 100
    let gotPacket = unsafe cesAcceptorPacket(acceptor, wait: wait)
    if due && !gotPacket && unsafe acceptor.pointee.core.liveCount != 0 { cesFailFast(stage: "server acceptor drain", error: 1460) }
  }
  return 0
}
package func cesInitializeAcceptor(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) -> CESFailure? {
  guard unsafe acceptor.pointee.configuration.workerCount > 0 && acceptor.pointee.configuration.workerCount <= CESConstants.maximumWorkers else { return .invariant("server acceptor worker table") }
  unsafe acceptor.pointee.listener.reset(cesRegisteredSocket(transport: .tcp))
  guard unsafe acceptor.pointee.listener.rawValue != ~SOCKET(0) else { return cesWinsockFailure("WSASocketW(TCP listener)") }
  unsafe acceptor.pointee.port.reset(CreateIoCompletionPort(HANDLE(bitPattern: -1), nil, 0, 1))
  guard unsafe acceptor.pointee.port.rawValue != nil else { return cesWin32Failure("CreateIoCompletionPort(acceptor)") }
  unsafe acceptor.pointee.readyEvent.reset(CreateEventW(nil, true, false, nil))
  guard unsafe acceptor.pointee.readyEvent.rawValue != nil else { return cesWin32Failure("CreateEventW(acceptor ready)") }
  let socket = unsafe acceptor.pointee.listener.rawValue
  if let failure = unsafe cesConfigureSocketFailure(socket, options: acceptor.pointee.configuration.options, tcp: true) { return failure }
  var address = SOCKADDR_IN(); address.sin_family = UInt16(AF_INET); address.sin_port = unsafe htons(acceptor.pointee.configuration.options.port)
  let bound = withUnsafePointer(to: &address) { unsafe bind(socket, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self), Int32(MemoryLayout<SOCKADDR_IN>.size)) }
  if bound != 0 || listen(socket, SOMAXCONN) != 0 { return cesWinsockFailure("bind/listen") }
  guard unsafe CreateIoCompletionPort(HANDLE(bitPattern: UInt(socket)), acceptor.pointee.port.rawValue, 0, 1) == acceptor.pointee.port.rawValue else { return cesWin32Failure("CreateIoCompletionPort(listener association)") }
  do { unsafe acceptor.pointee.acceptEx = unsafe try cesLoadAcceptEx(listener: socket); unsafe acceptor.pointee.acceptAddresses = unsafe try cesLoadAcceptAddresses(listener: socket) }
  catch { return error }
  guard let operations = unsafe CESPinnedStorage(count: Int(acceptor.pointee.operationCount), initialValue: CESAcceptOperation()), let addresses = unsafe CESPinnedStorage(count: Int(acceptor.pointee.operationCount) * CESConstants.acceptBufferBytes, initialValue: UInt8(0)) else { return .allocation("AcceptEx operation allocation") }
  unsafe acceptor.pointee.operationAddress = operations.baseAddress; unsafe acceptor.pointee.addressBuffer = addresses.baseAddress
  unsafe acceptor.pointee.operations = consume operations; unsafe acceptor.pointee.addresses = consume addresses
  for i in unsafe 0..<Int(acceptor.pointee.operationCount) {
    unsafe acceptor.pointee.operationAddress![i].owner = acceptor
    unsafe acceptor.pointee.operationAddress![i].index = UInt32(i)
    unsafe acceptor.pointee.operationAddress![i].acceptPort = acceptor.pointee.port.rawValue
    unsafe acceptor.pointee.operationAddress![i].addressOffset = i * CESConstants.acceptBufferBytes
  }
  return nil
}
package func cesStartAcceptor(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) -> CESFailure? {
  unsafe acceptor.pointee.thread.reset(CreateThread(nil, 0, cesAcceptorThread, acceptor, 0, nil))
  guard unsafe acceptor.pointee.thread.rawValue != nil else { return cesWin32Failure("CreateThread(acceptor)") }
  guard unsafe WaitForSingleObject(acceptor.pointee.readyEvent.rawValue, UInt32.max) == WAIT_OBJECT_0, unsafe acceptor.pointee.ready else { return .invariant("acceptor startup readiness") }
  return unsafe acceptor.pointee.startupOK ? nil : CESFailure(stage: "acceptor startup", code: 0)
}
package func cesPostAcceptorStop(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) {
  let ok = unsafe PostQueuedCompletionStatus(acceptor.pointee.port.rawValue, 0, UInt64(CESConstants.stopKey), nil)
  if !ok { cesFailFast(stage: "PostQueuedCompletionStatus(acceptor stop)", error: Int32(bitPattern: GetLastError())) }
}
package func cesJoinAcceptor(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) {
  if let thread = unsafe acceptor.pointee.thread.rawValue {
    if unsafe WaitForSingleObject(thread, UInt32.max) != WAIT_OBJECT_0 { cesFailFast(stage: "server acceptor join", error: Int32(bitPattern: GetLastError())) }
  }
  unsafe acceptor.pointee.joined = true
}
package func cesRequireAcceptorRelease(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) {
  if unsafe acceptor.pointee.thread.rawValue != nil && !acceptor.pointee.joined { cesFailFast(stage: "server acceptor release before join", error: 5023) }
  if unsafe acceptor.pointee.core.liveCount != 0 { cesFailFast(stage: "server acceptor release precondition", error: 996) }
  if let operations = unsafe acceptor.pointee.operationAddress {
    for i in unsafe 0..<Int(acceptor.pointee.operationCount) {
      if unsafe operations[i].providerOwned { cesFailFast(stage: "server acceptor release precondition", error: 996) }
    }
  }
}
package func cesDestroyAcceptor(_ acceptor: UnsafeMutablePointer<CESEngineAcceptor>) {
  unsafe cesRequireAcceptorRelease(acceptor)
  unsafe acceptor.pointee.thread.reset(); unsafe acceptor.pointee.listener.reset()
  if let operations = unsafe acceptor.pointee.operationAddress { for i in unsafe 0..<Int(acceptor.pointee.operationCount) { unsafe cesCloseAcceptSocket(operations.advanced(by: i)) } }
  unsafe acceptor.pointee.readyEvent.reset(); unsafe acceptor.pointee.port.reset()
  unsafe acceptor.pointee.operations = nil; unsafe acceptor.pointee.addresses = nil
  unsafe acceptor.pointee.operationAddress = nil; unsafe acceptor.pointee.addressBuffer = nil
}

@unsafe
private struct CESUdpRuntime: ~Copyable {
  private var engineStorage: CESUdpEngine
  var engine: CESUdpEngine { borrow { unsafe engineStorage } mutate { unsafe &engineStorage } }
  let rio: RIO_EXTENSION_FUNCTION_TABLE
  var socket = CESSocketOwner()
  var port = CESHandleOwner()
  var arena: CESRioArena?
  var queue = CESRIOCQOwner()
  var requestQueue: RIO_RQ?
  var slots: CESPinnedStorage<CESUdpSlot>?
  var notification: CESPinnedStorage<OVERLAPPED>?
  var results: CESPinnedStorage<RIORESULT>?
  var slotAddress: UnsafeMutablePointer<CESUdpSlot>?
  var notificationAddress: UnsafeMutablePointer<OVERLAPPED>?
  var resultsAddress: UnsafeMutablePointer<RIORESULT>?
  var providerOutstanding: UInt32 = 0
  var armed = false
  var snapshot = CESNotifySnapshot()
  var drainDeadline: UInt64?
  let depth: UInt32
  let capacity: UInt32
  init(rio: RIO_EXTENSION_FUNCTION_TABLE, options: borrowing CESOptions) throws(CESFailure) {
    unsafe self.rio = rio; unsafe depth = options.udpDepth; unsafe capacity = options.rioBufferBytes
    unsafe engineStorage = try CESUdpEngine(checkedDepth: options.udpDepth, payloadBytes: options.rioBufferBytes)
    guard let slots = unsafe CESPinnedStorage(count: Int(options.udpDepth), initialValue: CESUdpSlot()), let notification = unsafe CESPinnedStorage(count: 1, initialValue: OVERLAPPED()), let results = unsafe CESPinnedStorage(count: CESConstants.completionBatchSize, initialValue: RIORESULT()) else { throw .allocation("UDP allocation") }
    unsafe slotAddress = slots.baseAddress; unsafe notificationAddress = notification.baseAddress; unsafe resultsAddress = results.baseAddress
    unsafe self.slots = consume slots; unsafe self.notification = consume notification; unsafe self.results = consume results
    let raw = cesRegisteredSocket(transport: .udp)
    guard raw != ~SOCKET(0) else { throw cesWinsockFailure("WSASocketW(UDP)") }
    unsafe socket.reset(raw)
    if let failure = cesConfigureSocketFailure(raw, options: options, tcp: false) { throw failure }
    unsafe port.reset(CreateIoCompletionPort(HANDLE(bitPattern: -1), nil, 0, 1))
    guard unsafe port.rawValue != nil else { throw cesWin32Failure("CreateIoCompletionPort(UDP)") }
    let stride = options.rioBufferBytes + UInt32(CESConstants.udpAddressBytes)
    unsafe arena = unsafe try CESRioArena(rio: rio, slots: options.udpDepth, stride: stride, memoryLimit: options.memoryBytes)
    var address = SOCKADDR_IN(); address.sin_family = UInt16(AF_INET); address.sin_port = htons(options.port)
    let bound = withUnsafePointer(to: &address) { unsafe bind(raw, UnsafeRawPointer($0).assumingMemoryBound(to: SOCKADDR.self), Int32(MemoryLayout<SOCKADDR_IN>.size)) }
    if bound != 0 { throw cesWinsockFailure("bind(UDP)") }
    var description = unsafe RIO_NOTIFICATION_COMPLETION()
    unsafe description.Type = RIO_IOCP_COMPLETION; unsafe description.Iocp.IocpHandle = port.rawValue
    unsafe description.Iocp.CompletionKey = UnsafeMutableRawPointer(slotAddress!); unsafe description.Iocp.Overlapped = UnsafeMutableRawPointer(notificationAddress!)
    guard let cq = unsafe rio.RIOCreateCompletionQueue!(options.cqCapacity, &description) else { throw cesWinsockFailure("RIOCreateCompletionQueue(UDP)") }
    unsafe queue.reset(rio: rio, value: cq)
    unsafe requestQueue = unsafe rio.RIOCreateRequestQueue!(raw, options.udpDepth, 1, options.udpDepth, 1, cq, cq, slotAddress)
    guard unsafe requestQueue != nil else {
      let failure = cesWinsockFailure("RIOCreateRequestQueue(UDP)")
      // Withdraw the CQ binding and IOCP before fixed notification storage drops.
      unsafe queue.reset()
      unsafe arena?.release(providerOutstanding: 0, businessOutstanding: 0); unsafe arena = nil
      unsafe port.reset()
      throw failure
    }
    for i in 0..<Int(options.udpDepth) {
      unsafe slotAddress![i].index = UInt32(i)
      unsafe slotAddress![i].payload = arena!.view(index: UInt32(i), offset: 0, length: options.rioBufferBytes)
      unsafe slotAddress![i].remoteAddress = arena!.view(index: UInt32(i), offset: options.rioBufferBytes, length: UInt32(CESConstants.udpAddressBytes))
    }
  }
  mutating func beginDrain() {
    _ = unsafe engine.onEvent(.stop)
    if unsafe drainDeadline == nil { unsafe drainDeadline = cesSaturatingAdd(GetTickCount64(), CESConstants.drainGraceMilliseconds) }
    unsafe socket.reset()
  }
  borrowing func requireRelease() {
    unsafe cesRequireRelease(providerOutstanding: providerOutstanding, businessOutstanding: engine.outstanding, stage: "UDP cleanup with outstanding operations")
    if let slots = unsafe slotAddress { for i in unsafe 0..<Int(depth) { if unsafe slots[i].providerOperation != nil { cesFailFast(stage: "UDP cleanup with outstanding operations", error: 996) } } }
  }
  mutating func release() {
    unsafe requireRelease()
    unsafe socket.reset(); unsafe queue.reset()
    unsafe arena?.release(providerOutstanding: providerOutstanding, businessOutstanding: engine.outstanding); unsafe arena = nil
    unsafe port.reset()
    unsafe requestQueue = nil; unsafe slots = nil; unsafe notification = nil; unsafe results = nil
    unsafe slotAddress = nil; unsafe notificationAddress = nil; unsafe resultsAddress = nil
  }
  deinit {
    unsafe requireRelease()
    if unsafe queue.rawValue != nil || port.rawValue != nil { cesFailFast(stage: "UDP requires explicit resource teardown", error: 5023) }
  }
}
private func cesUdpExecute(_ runtime: UnsafeMutablePointer<CESUdpRuntime>, action: CESUdpAction, failureStage: String) {
  switch action {
  case .none: return
  case .fatal(let failure):
    if failure.classification != .network { cesFailFast(stage: failure.stage, error: failure.code) }
    cesReport(stage: failure.stage, error: failure.code); unsafe runtime.pointee.beginDrain()
  case .post(let index, let operation, let length):
    guard unsafe index < runtime.pointee.depth && length <= runtime.pointee.capacity else { cesFailFast(stage: "UDP post exceeds registration", error: 13) }
    let slot = unsafe runtime.pointee.slotAddress!.advanced(by: Int(index))
    guard unsafe slot.pointee.providerOperation == nil else { cesFailFast(stage: "UDP slot reuse", error: 13) }
    unsafe slot.pointee.payload.Length = length
    let rio = unsafe runtime.pointee.rio
    let posted = operation == .receive
      ? unsafe rio.RIOReceiveEx!(runtime.pointee.requestQueue, &slot.pointee.payload, 1, nil, &slot.pointee.remoteAddress, nil, nil, 0, slot) != 0
      : unsafe rio.RIOSendEx!(runtime.pointee.requestQueue, &slot.pointee.payload, 1, nil, &slot.pointee.remoteAddress, nil, nil, 0, slot).boolValue
    if !posted {
      let failure = cesWinsockFailure(failureStage)
      let next = unsafe runtime.pointee.engine.onEvent(.postFailed(index: index, failure: failure))
      unsafe cesUdpExecute(runtime, action: next, failureStage: failureStage); return
    }
    unsafe slot.pointee.providerOperation = operation; unsafe slot.pointee.postedLength = length
    unsafe runtime.pointee.providerOutstanding += 1; unsafe runtime.pointee.arena!.didPost()
    if unsafe !runtime.pointee.engine.markPosted(index: index, operation: operation) { cesFailFast(stage: "UDP post ownership", error: 13) }
  }
}
private func cesUdpDrain(_ runtime: UnsafeMutablePointer<CESUdpRuntime>, batches: Int = 64, recordBudget: UInt32? = nil) {
  var remaining = recordBudget
  for _ in 0..<batches {
    let capacity = min(UInt32(CESConstants.completionBatchSize), remaining ?? UInt32(CESConstants.completionBatchSize))
    if capacity == 0 { return }
    let count = unsafe cesRequireValidDequeueCount(runtime.pointee.rio.RIODequeueCompletion!(runtime.pointee.queue.rawValue, runtime.pointee.resultsAddress, capacity), stage: "RIODequeueCompletion(UDP)")
    guard count <= capacity else { cesFailFast(stage: "server UDP dequeue batch", error: 13) }
    if count == 0 { return }
    if remaining != nil { remaining! -= count }
    for i in 0..<Int(count) {
      let result = unsafe runtime.pointee.resultsAddress![i]
      guard let slot = unsafe cesUdpSlotForAddress(slots: runtime.pointee.slotAddress!, count: Int(runtime.pointee.depth), address: UInt(result.RequestContext)),
        let operation = unsafe slot.pointee.providerOperation, unsafe runtime.pointee.providerOutstanding != 0,
        unsafe result.BytesTransferred <= slot.pointee.postedLength else { cesFailFast(stage: "UDP completion ownership/range", error: 13) }
      unsafe slot.pointee.providerOperation = nil; unsafe slot.pointee.postedLength = 0
      unsafe runtime.pointee.providerOutstanding -= 1; unsafe runtime.pointee.arena!.didComplete()
      let event = CESEvent.completion(CESCompletion(index: unsafe slot.pointee.index, operation: operation, status: result.Status, bytes: result.BytesTransferred))
      let action = unsafe runtime.pointee.engine.onEvent(event)
      unsafe cesUdpExecute(runtime, action: action, failureStage: "UDP RIO repost")
    }
  }
}
private func cesUdpArm(_ runtime: UnsafeMutablePointer<CESUdpRuntime>) {
  if unsafe runtime.pointee.providerOutstanding != 0 && !runtime.pointee.armed {
    unsafe runtime.pointee.notificationAddress!.pointee = OVERLAPPED()
    cesRequireRIONotifySuccess(unsafe runtime.pointee.rio.RIONotify!(runtime.pointee.queue.rawValue), stage: "RIONotify(UDP)")
    unsafe runtime.pointee.armed = true; unsafe runtime.pointee.snapshot.arms &+= 1
  }
}
private func cesUdpRun(_ runtime: UnsafeMutablePointer<CESUdpRuntime>, options: borrowing CESOptions, control: CESSharedControl) -> CESExitCode {
  for i in unsafe 0..<runtime.pointee.depth {
    unsafe cesUdpExecute(runtime, action: .post(index: i, operation: .receive, length: runtime.pointee.capacity), failureStage: "RIOReceiveEx(UDP)")
    if unsafe runtime.pointee.engine.failed { break }
  }
  let start = GetTickCount64()
  let runDeadline = options.runSeconds == 0 ? UInt64.max : cesSaturatingAdd(start, UInt64(options.runSeconds) * 1000)
  var overdueBudget: UInt32?
  while unsafe !runtime.pointee.engine.closing || runtime.pointee.engine.outstanding != 0 {
    unsafe cesUdpArm(runtime)
    if unsafe runtime.pointee.engine.closing || control.stopRequested.load(ordering: .acquiring) || GetTickCount64() >= runDeadline { unsafe runtime.pointee.beginDrain() }
    let now = GetTickCount64(), deadline = unsafe runtime.pointee.drainDeadline
    let due = deadline.map { now >= $0 } ?? false
    if due {
      if overdueBudget == nil { overdueBudget = unsafe runtime.pointee.depth + 1 }
      if overdueBudget == 0 {
        unsafe cesUdpDrain(runtime, batches: Int(runtime.pointee.depth), recordBudget: runtime.pointee.depth)
        if unsafe runtime.pointee.engine.outstanding == 0 { break }
        cesFailFast(stage: "server UDP drain", error: 1460)
      }
      overdueBudget! -= 1
    }
    var transferred: DWORD = 0; var key: UInt64 = 0; var overlap: UnsafeMutablePointer<OVERLAPPED>?
    let wait = deadline.map { UInt32(min($0 > now ? $0 - now : 0, 100)) } ?? 100
    let ok = unsafe GetQueuedCompletionStatus(runtime.pointee.port.rawValue, &transferred, &key, &overlap, wait)
    let error = ok ? 0 : GetLastError()
    if unsafe overlap == runtime.pointee.notificationAddress {
      if !ok { cesFailFast(stage: "GetQueuedCompletionStatus(UDP notification)", error: Int32(bitPattern: error)) }
      unsafe cesRequireNotificationPacket(key: UInt(key), overlapped: overlap, expectedKey: UInt(bitPattern: runtime.pointee.slotAddress!), expectedOverlapped: runtime.pointee.notificationAddress, stage: "server UDP RIO notification key")
      if unsafe !cesNotificationMarkDelivered(&runtime.pointee.armed) { cesFailFast(stage: "server UDP notification delivery transition", error: 5023) }
      unsafe runtime.pointee.snapshot.deliveries &+= 1; unsafe cesUdpDrain(runtime)
    } else if !ok && error == WAIT_TIMEOUT && unsafe overlap == nil {
      if unsafe !runtime.pointee.engine.closing && runtime.pointee.providerOutstanding != 0 && !runtime.pointee.armed { unsafe runtime.pointee.snapshot.timeoutWakeups &+= 1 }
      if due {
        unsafe cesUdpDrain(runtime, batches: Int(runtime.pointee.depth), recordBudget: runtime.pointee.depth)
        if unsafe runtime.pointee.engine.outstanding != 0 { cesFailFast(stage: "server UDP drain", error: 1460) }
      }
    } else if !ok { cesFailFast(stage: "GetQueuedCompletionStatus(UDP)", error: Int32(bitPattern: error)) }
    else { cesFailFast(stage: "unexpected UDP IOCP packet", error: 13) }
  }
  unsafe runtime.pointee.requireRelease()
  let drained = unsafe runtime.pointee.engine.onEvent(.generationDrained)
  if case .fatal(let failure) = drained { cesFailFast(stage: failure.stage, error: failure.code) }
  guard unsafe runtime.pointee.engine.mayRelease && runtime.pointee.snapshot.valid else { cesFailFast(stage: "UDP release precondition", error: 13) }
  let statistics = unsafe runtime.pointee.engine.statistics
  let failed = unsafe runtime.pointee.engine.failed
  let snapshot = unsafe runtime.pointee.snapshot
  unsafe runtime.pointee.release()
  cesWriteNotificationDiagnostics(snapshot, protocolKind: .udp, workerIndex: 0)
  if options.stats { cesPrintFinalStatistics(protocolKind: .udp, statistics: statistics, elapsedMilliseconds: GetTickCount64() - start, terminalCount: 0, workerCount: 1) }
  return failed ? .network : .success
}
package func cesRunUDPServer(rio: RIO_EXTENSION_FUNCTION_TABLE, options: borrowing CESOptions, control: CESSharedControl) -> CESExitCode {
  do {
    var runtime = unsafe try CESUdpRuntime(rio: rio, options: options)
    let reference = Ref(options)
    return unsafe withUnsafeMutablePointer(to: &runtime) { unsafe cesUdpRun($0, options: reference.value, control: control) }
  } catch {
    if error.classification != .network { cesFailFast(stage: error.stage, error: error.code) }
    if error.code != 0 { cesReport(stage: error.stage, error: error.code) }
    if options.stats {
      var statistics = CESEngineStatistics()
      if error.domain != .allocation { statistics.networkErrors = 1 }
      cesPrintFinalStatistics(protocolKind: .udp, statistics: statistics, elapsedMilliseconds: 0, terminalCount: 0, workerCount: 1)
    }
    return .network
  }
}

