import WinSDK

// Unsafe native records expose pinned addresses and function-table entries.
// The coordinator initializes them before CreateThread; the owning thread then
// mutates connection state, timers and outstanding counts until join. Stored
// field offsets always describe the actual POD layout, and native completion
// identities are range/identity checked before those views are used.

package enum CESWorkerPhase: UInt8 { case starting, running, admissionClosed, draining, stopped }
package struct CESWorkerLifecycle {
  package var phase: CESWorkerPhase = .starting
  package var activeConnections: UInt32 = 0
  package var pendingHandoffs: UInt32 = 0
  package var notificationArmed = false
}
// Handoffs are counted as zero because the acceptor thread is joined before the
// coordinator publishes the admission-closed barrier to every worker.
package func cesWorkerMayExit(_ v: CESWorkerLifecycle) -> Bool {
  v.phase.rawValue >= CESWorkerPhase.admissionClosed.rawValue && v.activeConnections == 0
    && v.pendingHandoffs == 0
}
package enum CESUDPPhase: UInt8 { case running, draining, stopped }
package func cesUdpMayRelease(phase: CESUDPPhase, outstanding: UInt32) -> Bool {
  phase == .stopped && outstanding == 0
}
package struct CESEngineStatistics {
  package var accepted: UInt64 = 0
  package var completions: UInt64 = 0
  package var receives: UInt64 = 0
  package var sends: UInt64 = 0
  package var bytes: UInt64 = 0
  package init() {}
  package init(
    accepted: UInt64, completions: UInt64, receives: UInt64, sends: UInt64, bytes: UInt64
  ) {
    self.accepted = accepted
    self.completions = completions
    self.receives = receives
    self.sends = sends
    self.bytes = bytes
  }
}
package func cesStatisticsAdd(_ total: inout CESEngineStatistics, _ value: borrowing CESEngineStatistics) {
  total.accepted &+= value.accepted
  total.completions &+= value.completions
  total.receives &+= value.receives
  total.sends &+= value.sends
  total.bytes &+= value.bytes
}
package enum CESEngineOperation: UInt8 { case receive, send }
@unsafe
package struct CESEngineRequest {
  package var connectionIndex: UInt32 = 0
  package var operation: CESEngineOperation = .receive
  package init() {}
  package init(connectionIndex: UInt32, operation: CESEngineOperation) {
    unsafe self.connectionIndex = connectionIndex
    unsafe self.operation = operation
  }
}
@unsafe
package struct CESEngineConnection {
  package var owner: UnsafeMutablePointer<CESEngineWorker>?
  package var socket: SOCKET = ~SOCKET(0)
  package var requestQueue: RIO_RQ?
  package var buffer = unsafe RIO_BUF()
  package var echoBytes = 0
  package var sendOffset = 0
  package var index: UInt32 = 0
  package var outstanding: UInt32 = 0
  package var deadline: UInt64 = 0
  package var active = false
  package var closing = false
  package init() {}
}
package enum CESAcceptState: UInt8 { case idle, posted, transit }
@unsafe
package struct CESAcceptOperation {
  package var overlapped = unsafe OVERLAPPED()
  package var owner: UnsafeMutablePointer<CESEngineAcceptor>?
  package var socket: SOCKET = ~SOCKET(0)
  package var acceptPort: HANDLE?
  package var addressOffset = 0
  package var index: UInt32 = 0
  package var state: CESAcceptState = .idle
  package init() {}
}
@unsafe
package struct CESUdpSlot {
  package var payload = unsafe RIO_BUF()
  package var remoteAddress = unsafe RIO_BUF()
  package var operation: CESEngineOperation = .receive
  package var outstanding = false
  package var index: UInt32 = 0
  package init() {}
}
// Notification registrations are lazy: the engines arm RIONotify only while requests
// are in flight and never hold one on an idle engine. A released connection set (or an
// empty UDP slot set) therefore implies no registration is outstanding at release, so
// there is nothing to drain or cancel before the completion queue is destroyed.
private func checkedOffset<Root, Field>(_ key: KeyPath<Root, Field>, stage: String) -> Int {
  guard let offset = MemoryLayout<Root>.offset(of: key) else {
    cesFailFast(stage: stage, error: 13)
  }
  return offset
}
private enum CESConnectionLayout {
  static let buffer = unsafe checkedOffset(
    \CESEngineConnection.buffer, stage: "server connection buffer layout")
}
private enum CESAcceptLayout {
  static let overlapped = unsafe checkedOffset(
    \CESAcceptOperation.overlapped, stage: "server accept overlapped layout")
}
// Only POD fields are exposed to Windows; addresses come from owned allocations.
package func cesConnectionBuffer(_ c: UnsafeMutablePointer<CESEngineConnection>)
  -> UnsafeMutablePointer<RIO_BUF>
{
  unsafe UnsafeMutableRawPointer(c).advanced(by: CESConnectionLayout.buffer)
    .assumingMemoryBound(to: RIO_BUF.self)
}
package func cesAcceptOverlapped(_ operation: UnsafeMutablePointer<CESAcceptOperation>)
  -> UnsafeMutablePointer<OVERLAPPED>
{
  unsafe UnsafeMutableRawPointer(operation).advanced(by: CESAcceptLayout.overlapped)
    .assumingMemoryBound(to: OVERLAPPED.self)
}
package func cesAcceptOperation(_ overlapped: UnsafeMutablePointer<OVERLAPPED>)
  -> UnsafeMutablePointer<CESAcceptOperation>
{
  unsafe UnsafeMutableRawPointer(overlapped).advanced(by: -CESAcceptLayout.overlapped)
    .assumingMemoryBound(to: CESAcceptOperation.self)
}
@unsafe
package struct CESWorkerConfiguration: ~Copyable {
  package let options: CESOptions
  package let rio: RIO_EXTENSION_FUNCTION_TABLE
  private let controlStorage: CESSharedControl
  package var control: CESSharedControl { borrow { unsafe controlStorage } }
  private let failureStorage: CESFailureFlag
  package var failure: CESFailureFlag { borrow { unsafe failureStorage } }
  package let workerIndex: UInt32
  package let slotCount: UInt32
  package let memoryShare: UInt64
  package init(
    options: CESOptions, rio: RIO_EXTENSION_FUNCTION_TABLE, control: CESSharedControl,
    failure: CESFailureFlag, workerIndex: UInt32, slotCount: UInt32, memoryShare: UInt64
  ) {
    unsafe self.options = options
    unsafe self.rio = rio
    unsafe self.controlStorage = control
    unsafe self.failureStorage = failure
    unsafe self.workerIndex = workerIndex
    unsafe self.slotCount = slotCount
    unsafe self.memoryShare = memoryShare
  }
}
@unsafe
package struct CESWorkerResources: ~Copyable {
  package var thread = unsafe CESHandleOwner()
  package var port = unsafe CESHandleOwner()
  package var readyEvent = unsafe CESHandleOwner()
  package var arena = unsafe CESVirtualArenaOwner()
  package var registration = unsafe CESRIORegistrationOwner()
  package var completionQueue = unsafe CESRIOCQOwner()
  private var socketStorage = UniqueArray<CESSocketOwner>()
  package var sockets: UniqueArray<CESSocketOwner> {
    borrow { unsafe socketStorage }
    mutate { unsafe &socketStorage }
  }
  package var connections: CESPinnedStorage<CESEngineConnection>?
  package var requests: CESPinnedStorage<CESEngineRequest>?
  package var notification: CESPinnedStorage<OVERLAPPED>?
  // Completion results are a native output buffer owned by the worker for its whole
  // lifetime, so a drain never re-initializes 256 records on the stack.
  package var results: CESPinnedStorage<RIORESULT>?
}
@unsafe
package struct CESEngineWorker: ~Copyable {
  private let configurationStorage: CESWorkerConfiguration
  package var configuration: CESWorkerConfiguration { borrow { unsafe configurationStorage } }
  package var resources = unsafe CESWorkerResources()
  package var timers: CESTimerHeap
  package var memory: UnsafeMutablePointer<UInt8>?
  package var connectionAddress: UnsafeMutablePointer<CESEngineConnection>?
  package var requestAddress: UnsafeMutablePointer<CESEngineRequest>?
  package var notificationAddress: UnsafeMutablePointer<OVERLAPPED>?
  package var resultsAddress: UnsafeMutablePointer<RIORESULT>?
  package var requestRange: Range<UInt> = 0..<0
  package var acceptorAddress: UnsafeMutablePointer<CESEngineAcceptor>?
  package var freeIndices = UniqueArray<UInt32>()
  package var slotCount: UInt32
  package var stride: UInt32
  package var freeCount: UInt32 = 0
  package var activeCount: UInt32 = 0
  package var workerIndex: UInt32
  package var acceptedCount: UInt64 = 0
  package var completionCount: UInt64 = 0
  package var receiveCount: UInt64 = 0
  package var sendCount: UInt64 = 0
  package var echoedBytes: UInt64 = 0
  package var notificationArmed = false
  package var stopping = false
  package var admissionClosed = false
  package var ready = false
  package var phase: CESWorkerPhase = .starting
  package init(configuration: consuming CESWorkerConfiguration) {
    unsafe slotCount = configuration.slotCount
    unsafe stride = configuration.options.rioBufferBytes
    unsafe workerIndex = configuration.workerIndex
    unsafe timers = CESTimerHeap(capacity: configuration.slotCount)
    unsafe self.configurationStorage = consume configuration
  }
}
@unsafe
package struct CESWorkerOwner: ~Copyable {
  package let baseAddress: UnsafeMutablePointer<CESEngineWorker>
  package init(configuration: consuming CESWorkerConfiguration) {
    unsafe baseAddress = .allocate(capacity: 1)
    unsafe baseAddress.initialize(to: CESEngineWorker(configuration: consume configuration))
  }
  deinit {
    unsafe cesDestroyWorker(baseAddress)
    unsafe baseAddress.deinitialize(count: 1)
    unsafe baseAddress.deallocate()
  }
}
@unsafe
package struct CESAcceptorConfiguration: ~Copyable {
  package let options: CESOptions
  private let controlStorage: CESSharedControl
  package var control: CESSharedControl { borrow { unsafe controlStorage } }
  private let failureStorage: CESFailureFlag
  package var failure: CESFailureFlag { borrow { unsafe failureStorage } }
  package let workers: UnsafeMutablePointer<CESEngineWorker>?
  package let workerCount: UInt32
  package init(
    options: CESOptions, control: CESSharedControl, failure: CESFailureFlag,
    workers: UnsafeMutablePointer<CESEngineWorker>?, workerCount: UInt32
  ) {
    unsafe self.options = options
    unsafe self.controlStorage = control
    unsafe self.failureStorage = failure
    unsafe self.workers = unsafe workers
    unsafe self.workerCount = workerCount
  }
}
@unsafe
package struct CESAcceptorResources: ~Copyable {
  package var listener = CESSocketOwner()
  package var port = unsafe CESHandleOwner()
  package var thread = unsafe CESHandleOwner()
  package var operations: CESPinnedStorage<CESAcceptOperation>?
  package var addresses: CESPinnedStorage<UInt8>?
  private var socketStorage = UniqueArray<CESSocketOwner>()
  package var operationSockets: UniqueArray<CESSocketOwner> {
    borrow { unsafe socketStorage }
    mutate { unsafe &socketStorage }
  }
}
@unsafe
package struct CESEngineAcceptor: ~Copyable {
  private let configurationStorage: CESAcceptorConfiguration
  package var configuration: CESAcceptorConfiguration { borrow { unsafe configurationStorage } }
  package var resources = unsafe CESAcceptorResources()
  package var acceptEx: LPFN_ACCEPTEX?
  package var operationAddress: UnsafeMutablePointer<CESAcceptOperation>?
  package var addressBuffer: UnsafeMutablePointer<UInt8>?
  package var operationCount: UInt32 = 0
  package var nextWorker: UInt32 = 0
  package var stopping = false
  package init(configuration: consuming CESAcceptorConfiguration) {
    unsafe self.configurationStorage = consume configuration
  }
}
