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
  // Fixed capacity for the whole worker lifetime. RigidArray would state that invariant
  // in the type, but the Swift 6.4.0 toolchain used here does not ship it yet (only
  // UniqueArray/UniqueBox/Ref are in scope), so the capacity is enforced explicitly:
  // the heap never grows past capacity and insertOrUpdate fails instead of reallocating.
  private var nodes = UniqueArray<CESTimerNode>()
  private var positions = UniqueArray<Int>()
  package init(capacity: UInt32) {
    self.capacity = Int(capacity)
    nodes.reserveCapacity(Int(capacity))
    positions.reserveCapacity(Int(capacity))
    for _ in 0..<capacity {
      nodes.append(CESTimerNode())
      positions.append(-1)
    }
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
