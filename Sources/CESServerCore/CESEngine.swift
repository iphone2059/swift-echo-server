import Foundation
import WinSDK

// Statistics are printed in the baseline format. TCP prints one record per worker
// after that worker has joined, then the aggregate terminal line; UDP prints only
// the aggregate line. Rates use a guard of one millisecond.
private let cesStatisticsLocale = Locale(identifier: "en_US_POSIX")
package func cesPrintWorkerStatistics(
  workerIndex: UInt32, statistics: borrowing CESEngineStatistics, active: UInt32
) {
  print(
    String(
      format:
        "[worker %u] accepted=%llu completions=%llu receives=%llu sends=%llu bytes=%llu active=%u",
      locale: cesStatisticsLocale, UInt32(workerIndex), UInt64(statistics.accepted),
      UInt64(statistics.completions), UInt64(statistics.receives), UInt64(statistics.sends),
      UInt64(statistics.bytes), UInt32(active)))
}
package func cesPrintFinalStatistics(
  protocolKind: CESProtocol, statistics: borrowing CESEngineStatistics,
  elapsedMilliseconds: UInt64, terminalCount: UInt32
) {
  let guardedElapsed = max(elapsedMilliseconds, 1)
  let mebibytesPerSecond =
    Double(statistics.bytes) / (1024 * 1024) / (Double(guardedElapsed) / 1000)
  if protocolKind == .tcp {
    print(
      String(
        format:
          "final protocol=tcp elapsed_ms=%llu accepted=%llu completions=%llu receives=%llu sends=%llu bytes=%llu MiB_per_sec=%.2f active=%u",
        locale: cesStatisticsLocale, UInt64(elapsedMilliseconds), UInt64(statistics.accepted),
        UInt64(statistics.completions), UInt64(statistics.receives), UInt64(statistics.sends),
        UInt64(statistics.bytes), mebibytesPerSecond, UInt32(terminalCount)))
    return
  }
  print(
    String(
      format:
        "final protocol=udp elapsed_ms=%llu completions=%llu receives=%llu sends=%llu bytes=%llu MiB_per_sec=%.2f outstanding=%u",
      locale: cesStatisticsLocale, UInt64(elapsedMilliseconds), UInt64(statistics.completions),
      UInt64(statistics.receives), UInt64(statistics.sends), UInt64(statistics.bytes),
      mebibytesPerSecond, UInt32(terminalCount)))
}
package func cesRunServer(options: borrowing CESOptions, control: CESSharedControl) -> CESExitCode
{
  do {
    let winsock = try CESWinSockOwner()
    let result = cesRunWithRIO(options: options, control: control)
    winsock.keepAlive()
    return result
  } catch {
    cesReport(stage: error.stage, error: error.code)
    return .network
  }
}
private func cesRunWithRIO(options: borrowing CESOptions, control: CESSharedControl) -> CESExitCode
{
  let rio: RIO_EXTENSION_FUNCTION_TABLE
  do { rio = try cesLoadRIO() } catch {
    cesReport(stage: error.stage, error: error.code)
    return .network
  }
  switch options.protocolKind {
  case .tcp: return cesRunTCPServer(rio: rio, options: options, control: control)
  case .udp: return cesRunUDPServer(rio: rio, options: options, control: control)
  case .none: return .usage
  }
}
