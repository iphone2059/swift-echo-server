// Pure TCP aggregate. Native resources and provider ownership live in Transport;
// this engine records requested operations, deadlines and echo decisions only.
package struct CESTcpEngine: ~Copyable {
  private var connections: CESFixedArray<CESConnection>
  package var timers: CESTimerHeap
  private var freeIndices: CESFixedArray<UInt32>
  package let slotCount: UInt32
  package private(set) var freeCount: UInt32
  package private(set) var activeCount: UInt32 = 0
  package private(set) var outstanding: UInt32 = 0
  package var statistics = CESEngineStatistics()
  package var phase: CESWorkerPhase = .starting
  package var stopping = false
  package var admissionClosed = false
  package var failure: CESFailure?
  private let timeoutMilliseconds: UInt64

  package init(slotCount: UInt32, timeoutMilliseconds: UInt64) {
    // Cold convenience for contract callers; production uses the fallible initializer.
    self = try! CESTcpEngine(checkedSlotCount: slotCount, timeoutMilliseconds: timeoutMilliseconds)
  }
  package init(checkedSlotCount: UInt32, timeoutMilliseconds: UInt64) throws(CESFailure) {
    guard checkedSlotCount > 0 else { throw .allocation("TCP connection allocation") }
    slotCount = checkedSlotCount; freeCount = checkedSlotCount
    self.timeoutMilliseconds = timeoutMilliseconds
    connections = try CESFixedArray(count: Int(checkedSlotCount), repeating: CESConnection())
    freeIndices = try CESFixedArray(count: Int(checkedSlotCount), repeating: UInt32(0))
    timers = try CESTimerHeap(checkedCapacity: checkedSlotCount)
    for i in 0..<Int(checkedSlotCount) {
      connections[i].index = UInt32(i)
      freeIndices[i] = checkedSlotCount - UInt32(i) - 1
    }
  }
  package borrowing func connection(_ index: UInt32) -> CESConnection? {
    index < slotCount ? connections[Int(index)] : nil
  }
  package mutating func takeSlot() -> UInt32? {
    guard !stopping && freeCount > 0 else { return nil }
    freeCount -= 1
    return freeIndices[Int(freeCount)]
  }
  package mutating func returnSlot(_ index: UInt32) {
    guard index < slotCount && freeCount < slotCount else { failure = .invariant("TCP free list"); return }
    connections[Int(index)].state = .idle
    freeIndices[Int(freeCount)] = index; freeCount += 1
  }
  package mutating func adoptNext(now: UInt64) -> CESAction? {
    guard let index = takeSlot() else { return nil }
    return admit(index: index, now: now)
  }
  package mutating func admit(index: UInt32, now: UInt64) -> CESAction? {
    guard index < slotCount, connections[Int(index)].state == .idle || connections[Int(index)].state == .released else {
      failure = .invariant("TCP admission state"); return nil
    }
    var c = connections[Int(index)]
    c.admit(now: now, timeout: timeoutMilliseconds); c.outstanding = 1
    connections[Int(index)] = c
    activeCount += 1; outstanding += 1; statistics.accepted &+= 1
    schedule(index: index, deadline: c.deadline)
    return .receive(index: index, deadline: c.deadline)
  }
  private mutating func schedule(index: UInt32, deadline: UInt64) {
    if !timers.insertOrUpdate(connectionIndex: index, deadline: deadline) {
      failure = .invariant("server timer insert/update")
    }
  }
  private mutating func release(_ index: UInt32) -> CESAction {
    var c = connections[Int(index)]
    guard c.outstanding == 0, activeCount != 0 else {
      failure = .invariant("TCP release ownership"); return .close(index: index)
    }
    _ = timers.remove(connectionIndex: index)
    c.state = .idle; c.echoBytes = 0; c.sendOffset = 0
    connections[Int(index)] = c
    activeCount -= 1
    freeIndices[Int(freeCount)] = index; freeCount += 1
    return .release(index: index)
  }
  package mutating func close(index: UInt32, now: UInt64) -> CESAction? {
    guard index < slotCount else { failure = .invariant("TCP close index"); return nil }
    var c = connections[Int(index)]
    guard c.isActive && c.state != .closing else { return nil }
    let step = c.close(now: now)
    connections[Int(index)] = c
    if case .release = step { return release(index) }
    schedule(index: index, deadline: c.deadline)
    return .close(index: index)
  }
  package mutating func onEvent(_ event: CESEvent, now: UInt64) -> CESAction? {
    switch event {
    case .completion(let c): return onCompletion(c, now: now)
    case .postFailed(let i, let f): return onPostFailure(index: i, failure: f, now: now)
    case .admissionClosed: admissionClosed = true; phase = stopping ? .draining : .admissionClosed; return nil
    default: failure = .invariant("TCP engine event"); return nil
    }
  }
  package mutating func onCompletion(_ value: CESCompletion, now: UInt64) -> CESAction? {
    let i = value.index
    guard i < slotCount else { failure = .invariant("TCP completion index"); return nil }
    var c = connections[Int(i)]
    guard c.isActive && c.outstanding != 0 && outstanding != 0 else {
      failure = .invariant("TCP completion ownership"); return nil
    }
    statistics.record(value, closing: c.state == .closing)
    if c.state != .closing && value.status == 0 && value.operation == .send &&
      (value.bytes == 0 || c.sendOffset > c.echoBytes || value.bytes > c.echoBytes - c.sendOffset) {
      statistics.networkErrors &+= 1
    }
    outstanding -= 1
    let step = c.onCompletion(value, now: now, timeout: timeoutMilliseconds)
    connections[Int(i)] = c
    switch step {
    case .none: return nil
    case .release: return release(i)
    case .close: schedule(index: i, deadline: c.deadline); return .close(index: i)
    case .receive, .send: break
    }
    c.outstanding += 1; outstanding += 1
    connections[Int(i)] = c; schedule(index: i, deadline: c.deadline)
    switch step {
    case .receive: return .receive(index: i, deadline: c.deadline)
    case .send(let offset, let length): return .send(index: i, offset: offset, length: length, deadline: c.deadline)
    default: return nil
    }
  }
  package mutating func onPostFailure(index: UInt32, failure value: CESFailure, now: UInt64) -> CESAction? {
    guard value.classification == .network else { failure = value; return nil }
    failure = value
    guard index < slotCount && connections[Int(index)].outstanding != 0 && outstanding != 0 else {
      failure = .invariant("TCP refused post ownership"); return nil
    }
    connections[Int(index)].outstanding -= 1; outstanding -= 1
    statistics.networkErrors &+= 1
    return close(index: index, now: now)
  }
  package mutating func beginStop(index: UInt32, now: UInt64) -> CESAction? {
    stopping = true; phase = .draining
    return close(index: index, now: now)
  }
  package mutating func onTimeout(index: UInt32, now: UInt64) -> CESAction? {
    guard let c = connection(index), c.isActive else { return nil }
    if c.state == .closing {
      if c.outstanding != 0 { failure = .timeout("server connection drain") }
      return nil
    }
    return close(index: index, now: now)
  }
  package var lifecycle: CESWorkerLifecycle {
    CESWorkerLifecycle(phase: phase, activeConnections: activeCount, rioOutstanding: outstanding)
  }
  package var mayExit: Bool { cesWorkerMayExit(lifecycle) }
}
