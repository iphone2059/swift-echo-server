import Testing

@testable import CESServerCore

@Test func checkedProductReportsOverflow() {
  #expect(cesCheckedProduct(3, 4) == 12)
  #expect(cesCheckedProduct(0, UInt64.max) == 0)
  #expect(cesCheckedProduct(UInt64.max, 2) == nil)
}

@Test func checkedArenaBytesHonoursTheMemoryLimit() {
  #expect(cesCheckedArenaBytes(slots: 4, stride: 16, memoryLimit: 64) == 64)
  #expect(cesCheckedArenaBytes(slots: 4, stride: 16, memoryLimit: 63) == nil)
  #expect(cesCheckedArenaBytes(slots: UInt64.max, stride: 2, memoryLimit: UInt64.max) == nil)
}

@Test func tcpConnectionCapacityTakesTheSmallerBound() {
  #expect(cesTCPConnectionCapacity(cqCapacity: 4_096, memorySlots: 1_000) == 1_000)
  #expect(cesTCPConnectionCapacity(cqCapacity: 4_096, memorySlots: 100_000) == 2_048)
  #expect(cesTCPConnectionCapacity(cqCapacity: 64, memorySlots: 1) == 1)
}

@Test func offsetAdvanceRejectsImpossibleTransfers() {
  var offset = 0
  let partial = cesAdvanceOffset(total: 10, transferred: 4, offset: &offset)
  let complete = cesAdvanceOffset(total: 10, transferred: 6, offset: &offset)
  let past = cesAdvanceOffset(total: 10, transferred: 1, offset: &offset)
  let nothing = cesAdvanceOffset(total: 10, transferred: 0, offset: &offset)
  let negative = cesAdvanceOffset(total: 10, transferred: -1, offset: &offset)
  #expect(partial)
  #expect(complete)
  #expect(!past && !nothing && !negative)
  #expect(offset == 10)
}

@Test func udpSlotLookupRejectsAnythingOutsideTheSlotAllocation() {
  let count = 4
  let slots = UnsafeMutablePointer<CESUdpSlot>.allocate(capacity: count)
  slots.initialize(repeating: CESUdpSlot(), count: count)
  defer {
    slots.deinitialize(count: count)
    slots.deallocate()
  }
  for index in 0..<count { slots[index].index = UInt32(index) }
  let base = UInt(bitPattern: slots)
  let stride = UInt(MemoryLayout<CESUdpSlot>.stride)
  #expect(cesUdpSlotForAddress(slots: slots, count: count, address: base) != nil)
  #expect(cesUdpSlotForAddress(slots: slots, count: count, address: base + stride * 3) != nil)
  // One stride past the allocation, far past it, misaligned and below it must fail.
  #expect(cesUdpSlotForAddress(slots: slots, count: count, address: base + stride * 4) == nil)
  #expect(cesUdpSlotForAddress(slots: slots, count: count, address: base + stride * 1000) == nil)
  #expect(cesUdpSlotForAddress(slots: slots, count: count, address: base + 1) == nil)
  #expect(cesUdpSlotForAddress(slots: slots, count: count, address: base - stride) == nil)
  #expect(cesUdpSlotForAddress(slots: slots, count: 0, address: base) == nil)
  // A stride-aligned address inside the allocation with mismatched metadata is rejected.
  slots[2].index = 9
  #expect(cesUdpSlotForAddress(slots: slots, count: count, address: base + stride * 2) == nil)
  slots[2].index = 2
  #expect(cesUdpSlotForAddress(slots: slots, count: count, address: base + stride * 2) != nil)
}

@Test func notificationTransitionsAreOneWay() {
  var armed = false
  let deliveredWhileUnarmed = cesNotificationMarkDelivered(&armed)
  let rearms = cesNotificationMarkRearmed(&armed)
  let doubleRearm = cesNotificationMarkRearmed(&armed)
  let delivered = cesNotificationMarkDelivered(&armed)
  let duplicateDelivery = cesNotificationMarkDelivered(&armed)
  #expect(!deliveredWhileUnarmed)
  #expect(rearms)
  #expect(!doubleRearm)
  #expect(delivered)
  #expect(!duplicateDelivery)
}

@Test func workerReleaseRequiresTheAdmissionBarrier() {
  var lifecycle = CESWorkerLifecycle(
    phase: .starting, activeConnections: 0, pendingHandoffs: 0, notificationArmed: false)
  #expect(!cesWorkerMayExit(lifecycle))
  lifecycle.phase = .running
  #expect(!cesWorkerMayExit(lifecycle))
  lifecycle.phase = .admissionClosed
  #expect(cesWorkerMayExit(lifecycle))
  lifecycle.activeConnections = 1
  #expect(!cesWorkerMayExit(lifecycle))
  lifecycle.activeConnections = 0
  lifecycle.pendingHandoffs = 1
  #expect(!cesWorkerMayExit(lifecycle))
  lifecycle.pendingHandoffs = 0
  lifecycle.phase = .draining
  #expect(cesWorkerMayExit(lifecycle))
  lifecycle.phase = .stopped
  #expect(cesWorkerMayExit(lifecycle))
}

@Test func udpReleaseRequiresAStoppedPhaseAndNoOutstandingWork() {
  #expect(!cesUdpMayRelease(phase: .running, outstanding: 0))
  #expect(!cesUdpMayRelease(phase: .draining, outstanding: 0))
  #expect(!cesUdpMayRelease(phase: .stopped, outstanding: 1))
  #expect(cesUdpMayRelease(phase: .stopped, outstanding: 0))
}

@Test func statisticsAccumulateWithoutLosingFields() {
  var total = CESEngineStatistics()
  let first = CESEngineStatistics(
    accepted: 1, completions: 2, receives: 3, sends: 4, bytes: 5)
  let second = CESEngineStatistics(
    accepted: 6, completions: 7, receives: 8, sends: 9, bytes: 10)
  cesStatisticsAdd(&total, first)
  cesStatisticsAdd(&total, second)
  #expect(total.accepted == 7)
  #expect(total.completions == 9)
  #expect(total.receives == 11)
  #expect(total.sends == 13)
  #expect(total.bytes == 15)
}
