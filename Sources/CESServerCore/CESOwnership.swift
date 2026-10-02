import WinSDK

// Native adoption/reset transfers sole ownership; callers must pass a live
// resource and never reset to its already-owned value. Invalid sentinels are
// never released. The RIO table pointer belongs to Winsock, which outlives owners.
// Arena/CQ/registration owners are destroyed only after native cancellation drains
// and every engine thread has joined (cesDestroyWorker enforces the preconditions).

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
// Safe ownership and bounded views; raw adoption/access still has an unsafe
// pointer signature. The extent must match the adopted Windows allocation.
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
/// Owns a stable allocation. Native callbacks borrow this address until their owner joins.
@unsafe
package struct CESPinnedStorage<Element>: ~Copyable {
  package let count: Int
  package let baseAddress: UnsafeMutablePointer<Element>
  package init?(count: Int, initialValue: Element) {
    guard count > 0 else { return nil }
    let (bytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
    guard !overflow, let raw = unsafe HeapAlloc(GetProcessHeap(), 0, UInt64(bytes)) else {
      return nil
    }
    unsafe self.count = count
    unsafe baseAddress = unsafe raw.bindMemory(to: Element.self, capacity: count)
    unsafe baseAddress.initialize(repeating: initialValue, count: count)
  }
  deinit {
    unsafe baseAddress.deinitialize(count: count)
    unsafe HeapFree(GetProcessHeap(), 0, baseAddress)
  }
}
