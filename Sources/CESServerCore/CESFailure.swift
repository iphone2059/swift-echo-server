import Foundation
import WinSDK

package func cesReport(stage: String, error: Int32) {
  FileHandle.standardError.write(Data("\(stage) failed: native_error=\(error)\n".utf8))
}
// Internal invariant damage terminates deterministically with the internal exit code;
// no retry, no completion-queue polling and no fallback data path exist.
package func cesFailFast(stage: String, error: Int32) -> Never {
  cesReport(stage: stage, error: error)
  while true { unsafe TerminateProcess(GetCurrentProcess(), 4) }
}
package func cesRequireRIONotifySuccess(_ status: Int32, stage: String) {
  if status != 0 { cesFailFast(stage: stage, error: status) }
}
package func cesRequireValidDequeueCount(_ count: UInt32, stage: String) -> UInt32 {
  if count == UInt32.max { cesFailFast(stage: stage, error: 13) }
  return count
}
package func cesNotificationPacketMatches(
  key: UInt, overlapped: UnsafePointer<OVERLAPPED>?, expectedKey: UInt,
  expectedOverlapped: UnsafePointer<OVERLAPPED>?
) -> Bool { unsafe key == expectedKey && overlapped == expectedOverlapped }
package func cesRequireNotificationPacket(
  key: UInt, overlapped: UnsafePointer<OVERLAPPED>?, expectedKey: UInt,
  expectedOverlapped: UnsafePointer<OVERLAPPED>?, stage: String
) {
  if unsafe !cesNotificationPacketMatches(
    key: key, overlapped: overlapped, expectedKey: expectedKey,
    expectedOverlapped: expectedOverlapped)
  {
    cesFailFast(stage: stage, error: 13)
  }
}
package func cesRequireOutstanding(_ count: UInt32, stage: String) {
  if count == 0 { cesFailFast(stage: stage, error: 13) }
}
package func cesRequireControlPostSuccess(_ succeeded: Bool, error: Int32, stage: String) {
  if !succeeded { cesFailFast(stage: stage, error: error) }
}
