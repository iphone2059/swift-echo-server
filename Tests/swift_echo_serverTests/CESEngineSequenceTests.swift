import Synchronization
import Testing

@testable import CESServerCore

// These sequences catch premature recycling, lost drain traffic and a reset retaining
// the previous short send window. Expected actions are literal shared-contract data.
@Test func tcpPartialEchoAndCancelledDrainPreserveOwnership() {
  var engine = CESTcpEngine(slotCount: 1, timeoutMilliseconds: 1000)
  let admitted = engine.adoptNext(now: 10)
  #expect(admitted == .receive(index: 0, deadline: 1010))
  let send = engine.onCompletion(
    CESCompletion(index: 0, operation: .receive, status: 0, bytes: 10), now: 20)
  #expect(send == .send(index: 0, offset: 0, length: 10, deadline: 1020))
  let partial = engine.onCompletion(
    CESCompletion(index: 0, operation: .send, status: 0, bytes: 4), now: 30)
  #expect(partial == .send(index: 0, offset: 4, length: 6, deadline: 1030))
  _ = engine.beginStop(index: 0, now: 40)
  #expect(engine.activeCount == 1 && engine.outstanding == 1)
  let released = engine.onCompletion(
    CESCompletion(index: 0, operation: .send, status: 995, bytes: 0), now: 50)
  #expect(released == .release(index: 0))
  #expect(engine.freeCount == 1 && engine.outstanding == 0)
  #expect(engine.statistics.completions == 3 && engine.statistics.sends == 1)
  #expect(engine.statistics.bytes == 4 && engine.statistics.networkErrors == 0)
}

@Test func successfulCompletionDuringClosingStillCountsTraffic() {
  var engine = CESTcpEngine(slotCount: 1, timeoutMilliseconds: 1000)
  _ = engine.adoptNext(now: 0)
  _ = engine.beginStop(index: 0, now: 1)
  #expect(
    engine.onCompletion(CESCompletion(index: 0, operation: .receive, status: 0, bytes: 7), now: 2)
      == .release(index: 0))
  #expect(engine.statistics.receives == 1 && engine.statistics.receivedBytes == 7)
}

@Test func udpResetRestoresCapacityAndStopWaitsForRealCompletion() {
  var engine = CESUdpEngine(depth: 1, payloadBytes: 65507)
  let receivePosted = engine.markPosted(index: 0, operation: .receive)
  #expect(receivePosted)
  #expect(
    engine.onEvent(.completion(CESCompletion(index: 0, operation: .receive, status: 0, bytes: 23)))
      == .post(index: 0, operation: .send, length: 23))
  let sendPosted = engine.markPosted(index: 0, operation: .send)
  #expect(sendPosted)
  #expect(
    engine.onEvent(.completion(CESCompletion(index: 0, operation: .send, status: 10054, bytes: 0)))
      == .post(index: 0, operation: .receive, length: 65507))
  #expect(engine.statistics.sends == 0 && engine.statistics.networkErrors == 1)
  let receiveReposted = engine.markPosted(index: 0, operation: .receive)
  #expect(receiveReposted)
  _ = engine.onEvent(.stop)
  #expect(!engine.mayRelease && engine.outstanding == 1)
  #expect(
    engine.onEvent(.completion(CESCompletion(index: 0, operation: .receive, status: 995, bytes: 0)))
      == .none)
  _ = engine.onEvent(.generationDrained)
  #expect(engine.mayRelease && engine.statistics.completions == 3)
  #expect(engine.statistics.networkErrors == 1)
}

@Test func udpPrematureDrainAndDoublePostingHavePositiveControls() {
  var engine = CESUdpEngine(depth: 1, payloadBytes: 65507)
  let firstPost = engine.markPosted(index: 0, operation: .receive)
  #expect(firstPost)
  let secondPost = engine.markPosted(index: 0, operation: .receive)
  #expect(!secondPost)
  _ = engine.onEvent(.stop)
  #expect(engine.onEvent(.generationDrained) == .fatal(.invariant("UDP generation drain")))
  _ = engine.onEvent(
    .completion(CESCompletion(index: 0, operation: .receive, status: 995, bytes: 0)))
  #expect(engine.onEvent(.generationDrained) == .none)
  let mayReleaseAfterDrain = engine.mayRelease
  #expect(mayReleaseAfterDrain)
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
  var lifecycle = CESWorkerLifecycle(
    phase: .stopped, activeConnections: 0, pendingHandoffs: 0, notificationArmed: true)
  #expect(cesWorkerMayExit(lifecycle))
  lifecycle.rioOutstanding = 1
  #expect(!cesWorkerMayExit(lifecycle))
  #expect(CESNotifySnapshot(arms: 3, deliveries: 2).valid)
  #expect(!CESNotifySnapshot(arms: 3, deliveries: 1).valid)
}

@Test func tcpReleaseRejectsALeftoverTimerWithAValidEmptyControl() {
  var engine = CESTcpEngine(slotCount: 1, timeoutMilliseconds: 1000)
  engine.phase = .stopped
  engine.stopping = true
  engine.admissionClosed = true
  let mayExitBeforeTimer = engine.mayExit
  #expect(mayExitBeforeTimer)
  let inserted = engine.timers.insertOrUpdate(connectionIndex: 0, deadline: 10)
  #expect(inserted && !engine.mayExit)
  let removed = engine.timers.remove(connectionIndex: 0)
  #expect(removed && engine.mayExit)
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
  let receive = connection.onCompletion(
    CESCompletion(index: 0, operation: .receive, status: 0, bytes: 8), now: 1, timeout: 1000)
  if case .send(let offset, let length) = receive {
    #expect(offset == 0 && length == 8)
  } else {
    Issue.record("receive did not become echo send")
  }
  #expect(connection.state == .sending)
  connection.outstanding = 1
  _ = connection.close(now: 2)
  #expect(connection.state == .closing && connection.outstanding == 1)
  if case .release = connection.onCompletion(
    CESCompletion(index: 0, operation: .send, status: 995, bytes: 0), now: 3, timeout: 1000)
  {
  } else {
    Issue.record("final cancelled completion did not release")
  }
}

@Test func acceptorStopRetiresCompletionWithoutHandoff() throws {
  var core = try CESAcceptorCore(count: 1)
  let acceptPosted = core.markPosted(index: 0)
  #expect(acceptPosted)
  core.stopping = true
  if case .drop = core.onCompletion(index: 0, succeeded: true, code: 0) {
  } else {
    Issue.record("stop-raced accept must be dropped")
  }
  #expect(core.liveCount == 0)
  #expect(core.statistics.networkErrors == 0)
}

@Test func acceptorFindsCapacityBeyondItsRoundRobinCandidate() throws {
  var core = try CESAcceptorCore(count: 1, workers: 2)
  let first = CESAdmissionCredits(capacity: 1)
  let second = CESAdmissionCredits(capacity: 1)
  core.assignCredit(index: 0, credit: first)
  core.assignCredit(index: 1, credit: second)
  #expect(first.tryReserve())
  #expect(core.reserveWorker(candidate: 0) == 1)
  #expect(core.reserveWorker(candidate: 0) == nil)
  first.release()
  second.release()
  #expect(first.isFull && second.isFull)
}

@Test func acceptorHandoffPolicyDistinguishesShutdownFromBrokenOwnership() {
  let cases: [(Bool, Bool, Bool, Bool, CESAcceptHandoffDisposition)] = [
    (false, false, true, true, .handoff),
    (false, false, true, false, .fatal),
    (false, false, false, true, .withdraw),
    (false, false, false, false, .withdraw),
    (false, true, true, true, .withdraw),
    (false, true, true, false, .withdraw),
    (false, true, false, true, .withdraw),
    (false, true, false, false, .withdraw),
    (true, false, true, true, .withdraw),
    (true, false, true, false, .withdraw),
    (true, false, false, true, .withdraw),
    (true, false, false, false, .withdraw),
    (true, true, true, true, .withdraw),
    (true, true, true, false, .withdraw),
    (true, true, false, true, .withdraw),
    (true, true, false, false, .withdraw),
  ]
  for (stopping, failed, listenerValid, acceptedSocketValid, expected) in cases {
    #expect(
      cesAcceptHandoffDisposition(
        stopping: stopping, failed: failed,
        listenerValid: listenerValid, acceptedSocketValid: acceptedSocketValid) == expected)
  }
}

@Test func acceptorReturnAndDeferredRepostRejectIllegalTransitions() throws {
  var core = try CESAcceptorCore(count: 1)
  let idleReturn = core.returnSlot(index: 0)
  let outsideReturn = core.returnSlot(index: 1)
  let outsideDeferred = core.deferRepost(index: 1)
  let firstPost = core.markPosted(index: 0)
  let postedDeferred = core.deferRepost(index: 0)
  #expect(!idleReturn && !outsideReturn && !outsideDeferred)
  #expect(firstPost && !postedDeferred)
  // Synchronous refusal was never provider-owned and returns Posted to Idle.
  let refusedReturn = core.returnSlot(index: 0)
  let secondPost = core.markPosted(index: 0)
  #expect(refusedReturn && secondPost)
  if case .handoff = core.onCompletion(index: 0, succeeded: true, code: 0) {
  } else {
    Issue.record("successful accept did not begin handoff")
  }
  // A withdrawal before publication returns Transit to Idle without an ACK.
  let withdrawnReturn = core.returnSlot(index: 0)
  let firstDeferred = core.deferRepost(index: 0)
  let duplicateDeferred = core.deferRepost(index: 0)
  let deferredReturn = core.returnSlot(index: 0)
  #expect(withdrawnReturn && firstDeferred && !duplicateDeferred && !deferredReturn)
  #expect(core.states[0] == .deferred && core.liveCount == 1)
  if case .repost = core.onAck(index: 0) {
  } else {
    Issue.record("deferred repost did not retire its control packet")
  }
  #expect(core.liveCount == 0)
  core.stopping = true
  let stoppedDeferred = core.deferRepost(index: 0)
  let stoppedPost = core.markPosted(index: 0)
  #expect(!stoppedDeferred && !stoppedPost)
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
      let result = count.compareExchange(
        expected: old, desired: old + 1, ordering: .acquiringAndReleasing)
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
