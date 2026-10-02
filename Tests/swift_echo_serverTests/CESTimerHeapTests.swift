import Testing

@testable import CESServerCore

// Heap operations mutate, so every call is hoisted out of the expectation macro.
@Test func timerHeapOrdersByDeadlineThenIndex() {
  var heap = CESTimerHeap(capacity: 4)
  let insertedLatest = heap.insertOrUpdate(connectionIndex: 3, deadline: 100)
  let insertedFirst = heap.insertOrUpdate(connectionIndex: 1, deadline: 50)
  let insertedSecond = heap.insertOrUpdate(connectionIndex: 2, deadline: 50)
  #expect(insertedLatest && insertedFirst && insertedSecond)
  #expect(heap.waitMilliseconds(now: 0) == 50)
  let early = heap.popExpired(now: 49)
  let first = heap.popExpired(now: 50)
  let second = heap.popExpired(now: 50)
  let empty = heap.popExpired(now: 50)
  #expect(early == nil)
  #expect(first == 1)
  #expect(second == 2)
  #expect(empty == nil)
  let last = heap.popExpired(now: 100)
  #expect(last == 3)
  #expect(heap.size == 0)
  #expect(heap.waitMilliseconds(now: 0) == UInt32.max)
}

@Test func timerHeapUpdatesDeadlinesInPlace() {
  var heap = CESTimerHeap(capacity: 2)
  let inserted = heap.insertOrUpdate(connectionIndex: 0, deadline: 100)
  let secondInsert = heap.insertOrUpdate(connectionIndex: 1, deadline: 200)
  let moved = heap.insertOrUpdate(connectionIndex: 1, deadline: 10)
  #expect(inserted && secondInsert && moved)
  #expect(heap.waitMilliseconds(now: 0) == 10)
  let expired = heap.popExpired(now: 10)
  #expect(expired == 1)
  let refreshed = heap.insertOrUpdate(connectionIndex: 0, deadline: 100)
  #expect(refreshed)
  #expect(heap.size == 1)
  let removed = heap.remove(connectionIndex: 0)
  let removedAgain = heap.remove(connectionIndex: 0)
  #expect(removed)
  #expect(!removedAgain)
  #expect(heap.size == 0)
  let beyondCapacity = heap.insertOrUpdate(connectionIndex: 2, deadline: 1)
  #expect(!beyondCapacity)
}

@Test func timerHeapCapacityAndEmptyWaits() {
  var heap = CESTimerHeap(capacity: 0)
  #expect(heap.waitMilliseconds(now: 0) == UInt32.max)
  let expired = heap.popExpired(now: 1)
  let inserted = heap.insertOrUpdate(connectionIndex: 0, deadline: 1)
  let removed = heap.remove(connectionIndex: 0)
  #expect(expired == nil)
  #expect(!inserted)
  #expect(!removed)
}

@Test func timerHeapZeroRemainingDeadlineWaitsNotAtAll() {
  var heap = CESTimerHeap(capacity: 1)
  let inserted = heap.insertOrUpdate(connectionIndex: 0, deadline: 5)
  #expect(inserted)
  #expect(heap.waitMilliseconds(now: 5) == 0)
  #expect(heap.waitMilliseconds(now: 9) == 0)
  #expect(heap.waitMilliseconds(now: 1) == 4)
}
