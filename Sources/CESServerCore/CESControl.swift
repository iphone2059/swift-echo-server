import Synchronization
import WinSDK

// Safe public control interface: the console callback and every engine thread
// observe one atomic stop flag. The engine owns the object until all threads join.
package final class CESSharedControl: Sendable {
  package let stopRequested = Atomic<Bool>(false)
  package init() {}
}
package final class CESFailureFlag: Sendable {
  package let failed = Atomic<Bool>(false)
  package init() {}
}
// Console callbacks may overlap removal. The mutex protects only publication of the
// shared atomic container, whose retained reference outlives each callback.
private let cesConsoleControl = Mutex<CESSharedControl?>(nil)
private func cesConsoleHandler(_ type: DWORD) -> WindowsBool {
  guard
    type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT
  else { return false }
  cesConsoleControl.withLock { $0?.stopRequested.store(true, ordering: .releasing) }
  return true
}
package struct CESConsoleRegistration: ~Copyable {
  package borrowing func keepAlive() {}
  package init(control: CESSharedControl) throws(CESNativeError) {
    cesConsoleControl.withLock { $0 = control }
    guard SetConsoleCtrlHandler(cesConsoleHandler, true) else {
      cesConsoleControl.withLock { $0 = nil }
      throw CESNativeError(
        stage: "SetConsoleCtrlHandler", code: Int32(bitPattern: GetLastError()))
    }
  }
  deinit {
    SetConsoleCtrlHandler(cesConsoleHandler, false)
    cesConsoleControl.withLock { $0 = nil }
  }
}
