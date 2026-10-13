import Testing
import Synchronization
@testable import CESServerCore

// These sequences catch premature recycling, lost drain traffic and a reset retaining
// the previous short send window. Expected actions are literal shared-contract data.
@Test func tcpPartialEchoAndCancelledDrainPreserveOwnership() {
  var engine = CESTcpEngine(slotCount: 1, timeoutMilliseconds: 1000)
  let admitted = engine.adoptNext(now: 10)
  #expect(admitted == .receive(index: 0, deadline: 1010))
  let send = engine.onCompletion(CESCompletion(index: 0, operation: .receive, status: 0, bytes: 10), now: 20)
  #expect(send == .send(index: 0, offset: 0, length: 10, deadline: 1020))
  let partial = engine.onCompletion(CESCompletion(index: 0, operation: .send, status: 0, bytes: 4), now: 30)
  #expect(partial == .send(index: 0, offset: 4, length: 6, deadline: 1030))
  _ = engine.beginStop(index: 0, now: 40)
  #expect(engine.activeCount == 1 && engine.outstanding == 1)
  let released = engine.onCompletion(CESCompletion(index: 0, operation: .send, status: 995, bytes: 0), now: 50)
  #expect(released == .release(index: 0))
  #expect(engine.freeCount == 1 && engine.outstanding == 0)
  #expect(engine.statistics.completions == 3 && engine.statistics.sends == 1)
  #expect(engine.statistics.bytes == 4 && engine.statistics.networkErrors == 0)
}

@Test func successfulCompletionDuringClosingStillCountsTraffic() {
  var engine = CESTcpEngine(slotCount: 1, timeoutMilliseconds: 1000)
  _ = engine.adoptNext(now: 0)
  _ = engine.beginStop(index: 0, now: 1)
  #expect(engine.onCompletion(CESCompletion(index: 0, operation: .receive, status: 0, bytes: 7), now: 2) == .release(index: 0))
  #expect(engine.statistics.receives == 1 && engine.statistics.receivedBytes == 7)
}

@Test func udpResetRestoresCapacityAndStopWaitsForRealCompletion() {
  var engine = CESUdpEngine(depth: 1, payloadBytes: 65507)
  #expect(engine.markPosted(index: 0, operation: .receive))
  #expect(engine.onEvent(.completion(CESCompletion(index: 0, operation: .receive, status: 0, bytes: 23))) == .post(index: 0, operation: .send, length: 23))
  #expect(engine.markPosted(index: 0, operation: .send))
  #expect(engine.onEvent(.completion(CESCompletion(index: 0, operation: .send, status: 10054, bytes: 0))) == .post(index: 0, operation: .receive, length: 65507))
  #expect(engine.statistics.sends == 0 && engine.statistics.networkErrors == 1)
  #expect(engine.markPosted(index: 0, operation: .receive))
  _ = engine.onEvent(.stop)
  #expect(!engine.mayRelease && engine.outstanding == 1)
  #expect(engine.onEvent(.completion(CESCompletion(index: 0, operation: .receive, status: 995, bytes: 0))) == .none)
  _ = engine.onEvent(.generationDrained)
  #expect(engine.mayRelease && engine.statistics.completions == 3)
  #expect(engine.statistics.networkErrors == 1)
}

@Test func udpPrematureDrainAndDoublePostingHavePositiveControls() {
  var engine = CESUdpEngine(depth: 1, payloadBytes: 65507)
  #expect(engine.markPosted(index: 0, operation: .receive))
  #expect(!engine.markPosted(index: 0, operation: .receive))
  _ = engine.onEvent(.stop)
  #expect(engine.onEvent(.generationDrained) == .fatal(.invariant("UDP generation drain")))
  _ = engine.onEvent(.completion(CESCompletion(index: 0, operation: .receive, status: 995, bytes: 0)))
  #expect(engine.onEvent(.generationDrained) == .none)
  #expect(engine.mayRelease)
}

@Test func admissionCreditsIncludeHandoffsAndReturnExactlyOnce() {
  let credits = CESAdmissionCredits(capacity: 1)
  #expect(credits.tryReserve())
  #expect(!credits.tryReserve())
  credits.release()
  #expect(credits.isFull)
  #expect(credits.tryReserve())
  credits.release()
  #expect(credits.isFull)
}

@Test func releaseAllowsOneRealNotificationButNeverOutstandingIO() {
  var lifecycle = CESWorkerLifecycle(phase: .stopped, activeConnections: 0, pendingHandoffs: 0, notificationArmed: true)
  #expect(cesWorkerMayExit(lifecycle))
  lifecycle.rioOutstanding = 1
  #expect(!cesWorkerMayExit(lifecycle))
  #expect(CESNotifySnapshot(arms: 3, deliveries: 2).valid)
  #expect(!CESNotifySnapshot(arms: 3, deliveries: 1).valid)
}

@Test func deadlinesSaturateWithoutWrappingIntoThePast() {
  var engine = CESTcpEngine(slotCount: 1, timeoutMilliseconds: 1000)
  #expect(engine.adoptNext(now: UInt64.max - 3) == .receive(index: 0, deadline: UInt64.max))
  #expect(engine.beginStop(index: 0, now: UInt64.max - 2) == .close(index: 0))
  #expect(engine.connection(0)?.deadline == UInt64.max)
}

@Test func connectionOwnsItsEchoStateTransitions() {
  var connection = CESConnection()
  connection.admit(now: 0, timeout: 1000)
  connection.outstanding = 1
  let receive = connection.onCompletion(CESCompletion(index: 0, operation: .receive, status: 0, bytes: 8), now: 1, timeout: 1000)
  if case .send(let offset, let length) = receive { #expect(offset == 0 && length == 8) }
  else { Issue.record("receive did not become echo send") }
  #expect(connection.state == .sending)
  connection.outstanding = 1
  _ = connection.close(now: 2)
  #expect(connection.state == .closing && connection.outstanding == 1)
  if case .release = connection.onCompletion(CESCompletion(index: 0, operation: .send, status: 995, bytes: 0), now: 3, timeout: 1000) {}
  else { Issue.record("final cancelled completion did not release") }
}

@Test func acceptorStopRetiresCompletionWithoutHandoff() throws {
  var core = try CESAcceptorCore(count: 1)
  #expect(core.markPosted(index: 0))
  core.stopping = true
  if case .drop = core.onCompletion(index: 0, succeeded: true, code: 0) {}
  else { Issue.record("stop-raced accept must be dropped") }
  #expect(core.liveCount == 0)
  #expect(core.statistics.networkErrors == 0)
}

@Test func acceptorFindsCapacityBeyondItsRoundRobinCandidate() throws {
  var core = try CESAcceptorCore(count: 1, workers: 2)
  let first = CESAdmissionCredits(capacity: 1), second = CESAdmissionCredits(capacity: 1)
  core.assignCredit(index: 0, credit: first); core.assignCredit(index: 1, credit: second)
  #expect(first.tryReserve())
  #expect(core.reserveWorker(candidate: 0) == 1)
  #expect(core.reserveWorker(candidate: 0) == nil)
  first.release(); second.release()
  #expect(first.isFull && second.isFull)
}

@Test func fixedStorageRejectsOverflowAndPreservesSlots() throws {
  #expect(throws: CESFailure.self) { _ = try CESFixedArray(count: Int.max, repeating: UInt64(0)) }
  var values = try CESFixedArray(count: 2, repeating: UInt64(7))
  values[1] = 11
  #expect(values[0] == 7 && values[1] == 11)
}

private final class CESDropCounter: Sendable {
  let count = Atomic<Int>(0)
  func increment() {
    var old = count.load(ordering: .acquiring)
    while true {
      let result = count.compareExchange(expected: old, desired: old + 1, ordering: .acquiringAndReleasing)
      if result.exchanged { return }
      old = result.original
    }
  }
}
private final class CESCountedValue {
  let counter: CESDropCounter
  init(_ counter: CESDropCounter) { self.counter = counter }
  deinit { counter.increment() }
}
private func cesReleaseAllStorageElements(_ counter: CESDropCounter) throws {
  let value = CESCountedValue(counter)
  let values = try CESFixedArray(count: 2, repeating: value)
  #expect(values.count == 2)
}
@Test func fixedStorageDestroysEveryInitializedElement() throws {
  let counter = CESDropCounter()
  try cesReleaseAllStorageElements(counter)
  // Both references held by the allocation must be released for the single
  // object to die. A skipped element destructor would keep this count at zero.
  #expect(counter.count.load(ordering: .acquiring) == 1)
}
