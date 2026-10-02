import WinSDK
import ucrt

// Synchronous Windows calls borrow stack/buffer addresses only during the call.
// The RIO extension table is initialized by WSAIoctl and used while Winsock is
// active. AcceptEx entries belong to the listener socket and stay valid while that
// socket lives. The CRT owns argv and guarantees NUL termination.

package struct CESNativeError: Error {
  package let stage: String
  package let code: Int32
}
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
// Only AcceptEx is loaded: the AcceptEx output buffer is still required by the API,
// but an echo server does not consume the parsed peer address, so
// GetAcceptExSockaddrs is neither resolved nor called.
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
package func cesConfigureSocket(_ socket: SOCKET, options: borrowing CESOptions, tcp: Bool) -> Bool
{
  if options.socketBufferBytes > 0 {
    var size = Int32(options.socketBufferBytes)
    let status = withUnsafePointer(to: &size) { p in
      let bytes = unsafe UnsafeRawPointer(p).assumingMemoryBound(to: CChar.self)
      return unsafe setsockopt(socket, SOL_SOCKET, SO_SNDBUF, bytes, 4) == 0
        && setsockopt(socket, SOL_SOCKET, SO_RCVBUF, bytes, 4) == 0
    }
    if !status {
      cesReport(stage: "setsockopt(SO_SNDBUF/SO_RCVBUF)", error: WSAGetLastError())
      return false
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
      cesReport(stage: "setsockopt(TCP_NODELAY)", error: WSAGetLastError())
      return false
    }
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
