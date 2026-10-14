import Foundation
import WinSDK
import ucrt

// Synchronous Windows calls borrow stack/buffer addresses only during the call.
// The RIO extension table is initialized by WSAIoctl and used while Winsock is
// active. AcceptEx entries belong to the listener socket and stay valid while that
// socket lives. The CRT owns argv and guarantees NUL termination.

// AcceptEx and GetAcceptExSockaddrs belong to the listener's Winsock provider.
// The runtime validates the returned address views before publishing a handoff.

package typealias CESNativeError = CESFailure
package struct CESWinSockOwner: ~Copyable {
  package borrowing func keepAlive() {}
  package init() throws(CESNativeError) {
    var data = unsafe WSADATA()
    let status = unsafe WSAStartup(0x0202, &data)
    if status != 0 { throw CESNativeError(stage: "WSAStartup", code: status) }
  }
  deinit { WSACleanup() }
}
package func cesRegisteredSocket(transport: CESProtocol) -> SOCKET {
  WSASocketW(
    AF_INET, transport == .tcp ? SOCK_STREAM : SOCK_DGRAM,
    Int32((transport == .tcp ? IPPROTO_TCP : IPPROTO_UDP).rawValue), nil, 0,
    DWORD(UInt32(WSA_FLAG_OVERLAPPED) | UInt32(WSA_FLAG_REGISTERED_IO)))
}
package func cesLoadRIO() throws(CESNativeError) -> RIO_EXTENSION_FUNCTION_TABLE {
  let owner = CESSocketOwner(cesRegisteredSocket(transport: .tcp))
  guard owner.rawValue != ~SOCKET(0) else {
    throw CESNativeError(stage: "WSASocketW(RIO probe)", code: WSAGetLastError())
  }
  var rio = RIO_EXTENSION_FUNCTION_TABLE()
  rio.cbSize = DWORD(MemoryLayout<RIO_EXTENSION_FUNCTION_TABLE>.size)
  var rioID = GUID(
    Data1: 0x8509_e081, Data2: 0x96dd, Data3: 0x4005,
    Data4: (0xb1, 0x65, 0x9e, 0x2e, 0xe8, 0xc7, 0x9e, 0x3f))
  var bytes: DWORD = 0
  guard
    unsafe WSAIoctl(
      owner.rawValue, DWORD(0xC800_0024), &rioID, DWORD(MemoryLayout<GUID>.size), &rio,
      DWORD(MemoryLayout<RIO_EXTENSION_FUNCTION_TABLE>.size), &bytes, nil, nil) == 0
  else {
    throw CESNativeError(
      stage: "SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER(RIO)", code: WSAGetLastError())
  }
  return rio
}
package func cesLoadAcceptEx(listener: SOCKET) throws(CESNativeError) -> LPFN_ACCEPTEX {
  var acceptID = GUID(
    Data1: 0xb536_7df1, Data2: 0xcbac, Data3: 0x11cf,
    Data4: (0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92))
  var acceptEx: LPFN_ACCEPTEX?
  var bytes: DWORD = 0
  guard
    unsafe WSAIoctl(
      listener, DWORD(0xC800_0006), &acceptID, DWORD(MemoryLayout<GUID>.size), &acceptEx,
      DWORD(MemoryLayout<LPFN_ACCEPTEX?>.size), &bytes, nil, nil) == 0,
    unsafe acceptEx != nil
  else {
    throw CESNativeError(
      stage: "SIO_GET_EXTENSION_FUNCTION_POINTER(AcceptEx)", code: WSAGetLastError())
  }
  return unsafe acceptEx!
}
package func cesConfigureSocketFailure(_ socket: SOCKET, options: borrowing CESOptions, tcp: Bool)
  -> CESFailure?
{
  if options.socketBufferBytes > 0 {
    var size = Int32(options.socketBufferBytes)
    let status = withUnsafePointer(to: &size) { p in
      let bytes = unsafe UnsafeRawPointer(p).assumingMemoryBound(to: CChar.self)
      return unsafe setsockopt(socket, SOL_SOCKET, SO_SNDBUF, bytes, 4) == 0
        && setsockopt(socket, SOL_SOCKET, SO_RCVBUF, bytes, 4) == 0
    }
    if !status {
      return cesWinsockFailure("setsockopt(SO_SNDBUF/SO_RCVBUF)")
    }
  }
  if tcp {
    var enabled: Int32 = 1
    let status = withUnsafePointer(to: &enabled) {
      unsafe setsockopt(
        socket, Int32(IPPROTO_TCP.rawValue), TCP_NODELAY,
        UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self), 4)
    }
    if status != 0 {
      return cesWinsockFailure("setsockopt(TCP_NODELAY)")
    }
  }
  return nil
}
package func cesConfigureSocket(_ socket: SOCKET, options: borrowing CESOptions, tcp: Bool) -> Bool
{
  if let failure = cesConfigureSocketFailure(socket, options: options, tcp: tcp) {
    cesReport(stage: failure.stage, error: failure.code)
    return false
  }
  return true
}
package func cesWindowsArguments() throws(CESNativeError) -> [[UInt16]] {
  guard _configure_wide_argv(_crt_argv_unexpanded_arguments) == 0,
    let argv = unsafe __p___wargv().pointee
  else { throw CESNativeError(stage: "wide argv", code: 87) }
  let count = unsafe __p___argc().pointee
  var result: [[UInt16]] = []
  for i in 0..<Int(count) {
    guard let token = unsafe argv[i] else { throw CESNativeError(stage: "wide argv", code: 87) }
    var value: [UInt16] = []
    var n = 0
    while unsafe token[n] != 0 {
      unsafe value.append(token[n])
      n += 1
    }
    result.append(value)
  }
  return result
}

// Safe ownership and bounded views; raw adoption/access still has an unsafe
// pointer signature. The extent must match the adopted Windows allocation.

/// Owns a stable allocation. Native callbacks borrow this address until their owner joins.

package struct CESSocketOwner: ~Copyable {
  package private(set) var rawValue: SOCKET
  package init(_ value: SOCKET = ~SOCKET(0)) { rawValue = value }
  package mutating func reset(_ value: SOCKET = ~SOCKET(0)) {
    if rawValue != ~SOCKET(0) { closesocket(rawValue) }
    rawValue = value
  }
  package mutating func release() -> SOCKET {
    let value = rawValue
    rawValue = ~SOCKET(0)
    return value
  }
  deinit { if rawValue != ~SOCKET(0) { closesocket(rawValue) } }
}
@unsafe
package struct CESHandleOwner: ~Copyable {
  package private(set) var rawValue: HANDLE?
  package init(_ value: HANDLE? = nil) { unsafe rawValue = unsafe value }
  package mutating func reset(_ value: HANDLE? = nil) {
    if let rawValue = unsafe rawValue, unsafe rawValue != HANDLE(bitPattern: -1) {
      unsafe CloseHandle(rawValue)
    }
    unsafe rawValue = unsafe value
  }
  package mutating func release() -> HANDLE? {
    let value = unsafe rawValue
    unsafe rawValue = nil
    return unsafe value
  }
  deinit {
    if let rawValue = unsafe rawValue, unsafe rawValue != HANDLE(bitPattern: -1) {
      unsafe CloseHandle(rawValue)
    }
  }
}
@safe
package struct CESVirtualArenaOwner: ~Copyable {
  package private(set) var rawValue: UnsafeMutableRawPointer?
  package private(set) var byteCount: Int
  package init(_ value: UnsafeMutableRawPointer? = nil, byteCount: Int = 0) {
    unsafe rawValue = unsafe value
    self.byteCount = unsafe value == nil ? 0 : max(0, byteCount)
  }
  package mutating func reset(_ value: UnsafeMutableRawPointer? = nil, byteCount: Int = 0) {
    if let rawValue = unsafe rawValue { unsafe VirtualFree(rawValue, 0, DWORD(MEM_RELEASE)) }
    unsafe rawValue = unsafe value
    self.byteCount = unsafe value == nil ? 0 : max(0, byteCount)
  }
  package mutating func release() -> UnsafeMutableRawPointer? {
    let value = unsafe rawValue
    unsafe rawValue = nil
    byteCount = 0
    return unsafe value
  }
  package borrowing func withBytes<Result>(
    in range: Range<Int>, _ body: (borrowing Span<UInt8>) -> Result
  ) -> Result? {
    guard range.lowerBound >= 0, range.upperBound <= byteCount, let rawValue = unsafe rawValue
    else { return nil }
    let buffer = unsafe UnsafeBufferPointer(
      start: rawValue.assumingMemoryBound(to: UInt8.self).advanced(by: range.lowerBound),
      count: range.count)
    return unsafe body(Span(_unsafeElements: buffer))
  }
  package mutating func withMutableBytes<Result>(
    in range: Range<Int>, _ body: (inout MutableSpan<UInt8>) -> Result
  ) -> Result? {
    guard range.lowerBound >= 0, range.upperBound <= byteCount, let rawValue = unsafe rawValue
    else { return nil }
    let buffer = unsafe UnsafeMutableBufferPointer(
      start: rawValue.assumingMemoryBound(to: UInt8.self).advanced(by: range.lowerBound),
      count: range.count)
    var view = unsafe MutableSpan(_unsafeElements: buffer)
    return body(&view)
  }
  deinit {
    if let rawValue = unsafe rawValue { unsafe VirtualFree(rawValue, 0, DWORD(MEM_RELEASE)) }
  }
}
@unsafe
package struct CESRIORegistrationOwner: ~Copyable {
  private var rio = RIO_EXTENSION_FUNCTION_TABLE()
  package private(set) var rawValue: RIO_BUFFERID?
  package init() { unsafe rawValue = nil }
  package init(rio: RIO_EXTENSION_FUNCTION_TABLE, value: RIO_BUFFERID) {
    unsafe self.rio = rio
    unsafe rawValue = unsafe value
  }
  package mutating func reset() {
    if let rawValue = unsafe rawValue { unsafe rio.RIODeregisterBuffer!(rawValue) }
    unsafe rawValue = nil
  }
  package mutating func reset(rio: RIO_EXTENSION_FUNCTION_TABLE, value: RIO_BUFFERID) {
    unsafe reset()
    unsafe self.rio = rio
    unsafe rawValue = unsafe value
  }
  package mutating func release() -> RIO_BUFFERID? {
    let value = unsafe rawValue
    unsafe rawValue = nil
    return unsafe value
  }
  deinit { if let rawValue = unsafe rawValue { unsafe rio.RIODeregisterBuffer!(rawValue) } }
}
@unsafe
package struct CESRIOCQOwner: ~Copyable {
  private var rio = RIO_EXTENSION_FUNCTION_TABLE()
  package private(set) var rawValue: RIO_CQ?
  package init() { unsafe rawValue = nil }
  package init(rio: RIO_EXTENSION_FUNCTION_TABLE, value: RIO_CQ) {
    unsafe self.rio = rio
    unsafe rawValue = unsafe value
  }
  package mutating func reset() {
    if let rawValue = unsafe rawValue { unsafe rio.RIOCloseCompletionQueue!(rawValue) }
    unsafe rawValue = nil
  }
  package mutating func reset(rio: RIO_EXTENSION_FUNCTION_TABLE, value: RIO_CQ) {
    unsafe reset()
    unsafe self.rio = rio
    unsafe rawValue = unsafe value
  }
  package mutating func release() -> RIO_CQ? {
    let value = unsafe rawValue
    unsafe rawValue = nil
    return unsafe value
  }
  deinit { if let rawValue = unsafe rawValue { unsafe rio.RIOCloseCompletionQueue!(rawValue) } }
}
@unsafe
package struct CESPinnedStorage<Element>: ~Copyable {
  package let count: Int
  package let baseAddress: UnsafeMutablePointer<Element>
  package init?(count: Int, initialValue: Element) {
    guard count > 0 && MemoryLayout<Element>.alignment <= 16 else { return nil }
    let (bytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
    guard !overflow, let raw = unsafe HeapAlloc(GetProcessHeap(), 0, UInt64(bytes)) else {
      return nil
    }
    unsafe self.count = count
    unsafe baseAddress = unsafe raw.bindMemory(to: Element.self, capacity: count)
    unsafe baseAddress.initialize(repeating: initialValue, count: count)
  }
  // Explicit unsafe adoption for already initialized HeapAlloc storage. The caller
  // must transfer sole ownership from GetProcessHeap and keep no other owner.
  // Fault drivers intentionally violate this premise with a stack address to prove
  // that the enclosing release guard runs before this destructor can HeapFree it.
  package init(unsafeAdoptingHeapAllocation address: UnsafeMutablePointer<Element>, count: Int) {
    precondition(count > 0)
    unsafe self.count = count
    unsafe baseAddress = address
  }
  deinit {
    unsafe baseAddress.deinitialize(count: count)
    if unsafe !HeapFree(GetProcessHeap(), 0, baseAddress) {
      cesFailFast(stage: "pinned storage HeapFree", error: 487)
    }
  }
}

// Internal invariant damage terminates deterministically with the internal exit code;
// no retry, no completion-queue polling and no fallback data path exist.

// Fixed capacity, fallible storage. Only initialized elements can be borrowed;
// callers cannot widen a view or move the underlying allocation. HeapAlloc's
// Windows x64 alignment covers the POD values used here (at most 16 bytes).

// One VirtualAlloc, one independent registration per concurrently owned slot.
// Descriptor offsets are local to a registration, never global arena offsets.
package func cesReport(stage: StaticString, error: Int32) {
  FileHandle.standardError.write(Data("\(stage) failed: native_error=\(error)\n".utf8))
}
package func cesFailFast(stage: StaticString, error: Int32) -> Never {
  cesReport(stage: stage, error: error)
  while true { unsafe TerminateProcess(GetCurrentProcess(), 4) }
}
package func cesRequireRIONotifySuccess(_ status: Int32, stage: StaticString) {
  if status == 10037 { cesFailFast(stage: "RIONotify duplicate arm", error: status) }
  if status != 0 { cesFailFast(stage: stage, error: status) }
}
package func cesRequireValidDequeueCount(_ count: UInt32, stage: StaticString) -> UInt32 {
  if count == UInt32.max { cesFailFast(stage: stage, error: 13) }
  return count
}
package func cesRequireAcceptCompletionExtent(_ transferred: UInt32) {
  if transferred != 0 { cesFailFast(stage: "AcceptEx completion exceeds posted range", error: 13) }
}
package func cesRequireAcceptHandoffSocket(_ acceptedSocketValid: Bool) {
  if !acceptedSocketValid { cesFailFast(stage: "AcceptEx handoff invariant", error: 10038) }
}
package func cesNotificationPacketMatches(
  key: UInt, overlapped: UnsafePointer<OVERLAPPED>?, expectedKey: UInt,
  expectedOverlapped: UnsafePointer<OVERLAPPED>?
) -> Bool { unsafe key == expectedKey && overlapped == expectedOverlapped }
package func cesRequireNotificationPacket(
  key: UInt, overlapped: UnsafePointer<OVERLAPPED>?, expectedKey: UInt,
  expectedOverlapped: UnsafePointer<OVERLAPPED>?, stage: StaticString
) {
  if unsafe !cesNotificationPacketMatches(
    key: key, overlapped: overlapped, expectedKey: expectedKey,
    expectedOverlapped: expectedOverlapped)
  {
    cesFailFast(stage: stage, error: 13)
  }
}
package func cesRequireOutstanding(_ count: UInt32, stage: StaticString) {
  if count == 0 { cesFailFast(stage: stage, error: 13) }
}
package func cesRequireControlPostSuccess(_ succeeded: Bool, error: Int32, stage: StaticString) {
  if !succeeded { cesFailFast(stage: stage, error: error) }
}
@safe
package struct CESFixedArray<Element>: ~Copyable {
  private let storage: UnsafeMutablePointer<Element>?
  package let count: Int
  package init(count: Int, repeating value: Element) throws(CESFailure) {
    guard count >= 0 && MemoryLayout<Element>.alignment <= 16 else {
      throw .allocation("fixed array allocation")
    }
    if count == 0 {
      self.count = count
      unsafe storage = nil
      return
    }
    let (bytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
    guard !overflow, let raw = unsafe HeapAlloc(GetProcessHeap(), 0, UInt64(bytes)) else {
      throw .allocation("fixed array allocation")
    }
    self.count = count
    unsafe storage = raw.bindMemory(to: Element.self, capacity: count)
    unsafe storage!.initialize(repeating: value, count: count)
  }
  package subscript(index: Int) -> Element {
    get {
      precondition(index >= 0 && index < count)
      return unsafe storage![index]
    }
    set {
      precondition(index >= 0 && index < count)
      unsafe storage![index] = newValue
    }
  }
  deinit {
    if let storage = unsafe storage {
      unsafe storage.deinitialize(count: count)
      unsafe HeapFree(GetProcessHeap(), 0, storage)
    }
  }
}
package func cesPageBytes() -> UInt64 {
  var information = unsafe SYSTEM_INFO()
  unsafe GetSystemInfo(&information)
  return unsafe UInt64(information.dwPageSize)
}
package func cesActiveProcessorCount() -> UInt32 { GetActiveProcessorCount(0xffff) }
package func cesWin32Failure(_ stage: StaticString) -> CESFailure {
  CESFailure(domain: .win32, stage: stage, code: Int32(bitPattern: GetLastError()))
}
package func cesWinsockFailure(_ stage: StaticString) -> CESFailure {
  CESFailure(stage: stage, code: WSAGetLastError())
}
package func cesRequireRelease(
  providerOutstanding: UInt32, businessOutstanding: UInt32, stage: StaticString
) {
  if providerOutstanding != 0 || businessOutstanding != 0 { cesFailFast(stage: stage, error: 996) }
}
package func cesLoadAcceptAddresses(listener: SOCKET) throws(CESFailure)
  -> LPFN_GETACCEPTEXSOCKADDRS
{
  var identifier = GUID(
    Data1: 0xb536_7df2, Data2: 0xcbac, Data3: 0x11cf,
    Data4: (0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92))
  var function: LPFN_GETACCEPTEXSOCKADDRS?
  var bytes: DWORD = 0
  guard
    unsafe WSAIoctl(
      listener, DWORD(0xc800_0006), &identifier, DWORD(MemoryLayout<GUID>.size), &function,
      DWORD(MemoryLayout<LPFN_GETACCEPTEXSOCKADDRS?>.size), &bytes, nil, nil) == 0,
    unsafe function != nil
  else {
    throw cesWinsockFailure("SIO_GET_EXTENSION_FUNCTION_POINTER(GetAcceptExSockaddrs)")
  }
  return unsafe function!
}
@unsafe
package struct CESRioArena: ~Copyable {
  private var pages: CESVirtualArenaOwner
  private var registrations: CESFixedArray<RIO_BUFFERID?>
  private let rio: RIO_EXTENSION_FUNCTION_TABLE
  package let stride: UInt32
  package let slotCount: UInt32
  private var providerOutstanding: UInt32 = 0
  package init(
    rio: RIO_EXTENSION_FUNCTION_TABLE, slots: UInt32, stride: UInt32, memoryLimit: UInt64
  ) throws(CESFailure) {
    guard slots != 0 && stride != 0,
      let bytes = cesCheckedPageRoundedArenaBytes(
        slots: UInt64(slots), stride: UInt64(stride), memoryLimit: memoryLimit, page: cesPageBytes()
      ), bytes != 0 && bytes <= UInt64(UInt32.max)
    else {
      throw .allocation("arena capacity")
    }
    var registrations = unsafe try CESFixedArray(
      count: Int(slots), repeating: Optional<RIO_BUFFERID>.none)
    var pages = unsafe CESVirtualArenaOwner()
    let address = unsafe VirtualAlloc(
      nil, bytes, DWORD(UInt32(MEM_RESERVE) | UInt32(MEM_COMMIT)), DWORD(PAGE_READWRITE))
    guard let address = unsafe address else { throw cesWin32Failure("VirtualAlloc(arena)") }
    unsafe pages.reset(address, byteCount: Int(bytes))
    for i in 0..<Int(slots) {
      let base = unsafe address.advanced(by: i * Int(stride)).assumingMemoryBound(to: CChar.self)
      guard let registration = unsafe rio.RIORegisterBuffer!(base, stride) else {
        let failure = cesWinsockFailure("RIORegisterBuffer(slots)")
        for j in 0..<i {
          if let id = unsafe registrations[j] {
            unsafe rio.RIODeregisterBuffer!(id)
            unsafe registrations[j] = nil
          }
        }
        unsafe pages.reset()
        throw failure
      }
      unsafe registrations[i] = registration
    }
    unsafe self.rio = rio
    unsafe self.stride = stride
    unsafe slotCount = slots
    unsafe self.registrations = consume registrations
    unsafe self.pages = consume pages
  }
  package borrowing func view(index: UInt32, offset: UInt32, length: UInt32) -> RIO_BUF {
    guard unsafe index < slotCount, unsafe offset <= stride, unsafe length <= stride - offset,
      let id = unsafe registrations[Int(index)]
    else {
      cesFailFast(stage: "RIO registration window", error: 13)
    }
    var result = unsafe RIO_BUF()
    unsafe result.BufferId = id
    unsafe result.Offset = offset
    unsafe result.Length = length
    return unsafe result
  }
  package mutating func release(providerOutstanding: UInt32, businessOutstanding: UInt32) {
    cesRequireRelease(
      providerOutstanding: providerOutstanding, businessOutstanding: businessOutstanding,
      stage: "RIO arena release precondition")
    unsafe cesRequireRelease(
      providerOutstanding: self.providerOutstanding, businessOutstanding: 0,
      stage: "RIO arena provider ownership")
    unsafe deregister()
    unsafe pages.reset()
  }
  package mutating func didPost() { unsafe providerOutstanding += 1 }
  package mutating func didComplete() {
    if unsafe providerOutstanding == 0 {
      cesFailFast(stage: "RIO arena completion ownership", error: 13)
    }
    unsafe providerOutstanding -= 1
  }
  private mutating func deregister() {
    for i in unsafe 0..<registrations.count {
      if let id = unsafe registrations[i] {
        unsafe rio.RIODeregisterBuffer!(id)
        unsafe registrations[i] = nil
      }
    }
  }
  deinit {
    // This owner guards its own trusted ledger, including scope exit and rollback.
    // A caller passing zero to release cannot erase provider ownership.
    unsafe cesRequireRelease(
      providerOutstanding: providerOutstanding, businessOutstanding: 0,
      stage: "RIO arena provider ownership")
    for i in unsafe 0..<registrations.count {
      if let id = unsafe registrations[i] { unsafe rio.RIODeregisterBuffer!(id) }
    }
  }
}
