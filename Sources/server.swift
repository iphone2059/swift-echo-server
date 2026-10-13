import Foundation
import Synchronization
import WinSDK

// One process runs one server. The console callback uses a permanently retained
// atomic container, so handler removal cannot race reclamation or require a lock.
package final class CESSharedControl: Sendable {
  package let stopRequested = Atomic<Bool>(false)
  package init() {}
}
package final class CESFailureFlag: Sendable {
  package let failed = Atomic<Bool>(false)
  package init() {}
}
package let cesProcessControl = CESSharedControl()
private func cesConsoleHandler(_ kind: DWORD) -> WindowsBool {
  if kind == CTRL_C_EVENT || kind == CTRL_BREAK_EVENT || kind == CTRL_CLOSE_EVENT {
    cesProcessControl.stopRequested.store(true, ordering: .releasing); return true
  }
  return false
}
package struct CESConsoleRegistration: ~Copyable {
  package borrowing func keepAlive() {}
  package init(control: CESSharedControl) throws(CESFailure) {
    guard control === cesProcessControl else { throw .invariant("console control identity") }
    if !SetConsoleCtrlHandler(cesConsoleHandler, true) { throw cesWin32Failure("SetConsoleCtrlHandler") }
  }
  deinit { SetConsoleCtrlHandler(cesConsoleHandler, false) }
}
private let cesStatisticsLocale = Locale(identifier: "en_US_POSIX")
package func cesPrintFinalStatistics(protocolKind: CESProtocol, statistics: borrowing CESEngineStatistics, elapsedMilliseconds: UInt64, terminalCount: UInt32, workerCount: UInt32 = 1) {
  let rate = Double(statistics.bytes) / (1024 * 1024) / (Double(max(elapsedMilliseconds, 1)) / 1000)
  let name = protocolKind == .udp ? "udp" : "tcp"
  print(String(format: "final protocol=%@ elapsed_ms=%llu workers=%u accepted=%llu active=0 outstanding=%u completions=%llu receives=%llu sends=%llu received_bytes=%llu sent_bytes=%llu bytes=%llu network_errors=%llu rejected=%llu MiB_per_sec=%.2f", locale: cesStatisticsLocale,
    name, elapsedMilliseconds, workerCount, statistics.accepted, terminalCount,
    statistics.completions, statistics.receives, statistics.sends,
    statistics.receivedBytes, statistics.sentBytes, statistics.bytes,
    statistics.networkErrors, statistics.rejected, rate))
}
package func cesWriteNotificationDiagnostics(_ snapshot: CESNotifySnapshot, protocolKind: CESProtocol, workerIndex: UInt32) {
  guard let path = ProcessInfo.processInfo.environment["CES_DIAG_FILE"], !path.isEmpty && path.utf16.count < 512 else { return }
  let name = protocolKind == .udp ? "udp" : "tcp"
  let text = "role=server protocol=\(name) worker=\(workerIndex) notify_arms=\(snapshot.arms) notify_deliveries=\(snapshot.deliveries) notify_gap=\(snapshot.arms - snapshot.deliveries) timeout_wakeups_while_outstanding=\(snapshot.timeoutWakeups)\n"
  let data = Data(text.utf8)
  if workerIndex == 0 { _ = FileManager.default.createFile(atPath: path, contents: data); return }
  if let handle = FileHandle(forWritingAtPath: path) {
    do { try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close() }
    catch { return }
  } else {
    return
  }
}
package func cesResolvedWorkerCount(_ requested: UInt32, processors: UInt32) -> UInt32 {
  requested == 0 ? min(max(processors, 1), CESConstants.maximumWorkers) : requested
}
package func cesRunServer(options: borrowing CESOptions, control: CESSharedControl) -> CESExitCode {
  do {
    let winsock = try CESWinSockOwner()
    let rio = try cesLoadRIO()
    let result: CESExitCode
    switch options.protocolKind {
    case .tcp: result = cesRunTCPServer(rio: rio, options: options, control: control)
    case .udp: result = cesRunUDPServer(rio: rio, options: options, control: control)
    case .none: result = .usage
    }
    winsock.keepAlive(); return result
  } catch { cesReport(stage: error.stage, error: error.code); return .network }
}
package func cesRunTCPServer(rio: RIO_EXTENSION_FUNCTION_TABLE, options: borrowing CESOptions, control: CESSharedControl) -> CESExitCode {
  let count = cesResolvedWorkerCount(options.workerCount, processors: GetActiveProcessorCount(0xffff))
  let (workerBytes, workerOverflow) = unsafe MemoryLayout<CESEngineWorker>.stride.multipliedReportingOverflow(by: Int(count))
  guard !workerOverflow, let workerRaw = unsafe HeapAlloc(GetProcessHeap(), 0, UInt64(workerBytes)) else {
    cesReport(stage: "worker array allocation", error: 8); return .network
  }
  let workers = unsafe workerRaw.bindMemory(to: CESEngineWorker.self, capacity: Int(count))
  defer { unsafe HeapFree(GetProcessHeap(), 0, workerRaw) }
  guard let acceptorRaw = unsafe HeapAlloc(GetProcessHeap(), 0, UInt64(MemoryLayout<CESEngineAcceptor>.stride)) else {
    cesReport(stage: "acceptor allocation", error: 8); return .network
  }
  let acceptor = unsafe acceptorRaw.bindMemory(to: CESEngineAcceptor.self, capacity: 1)
  defer { unsafe HeapFree(GetProcessHeap(), 0, acceptorRaw) }
  var snapshots: CESFixedArray<CESNotifySnapshot>
  do { snapshots = try CESFixedArray(count: Int(count), repeating: CESNotifySnapshot()) }
  catch { cesReport(stage: error.stage, error: error.code); return .network }
  let failure = CESFailureFlag()
  var constructed: UInt32 = 0
  var started: UInt32 = 0
  var acceptorConstructed = false
  var statistics = CESEngineStatistics()
  for index in 0..<count {
    let budget = cesWorkerMemoryBudget(memory: options.memoryBytes, workers: count, index: index, page: cesPageBytes())
    let slots = cesTCPConnectionCapacity(cqCapacity: options.cqCapacity, memorySlots: budget / UInt64(options.rioBufferBytes))
    if slots == 0 { cesReport(stage: "TCP worker registered arena capacity", error: 8); failure.failed.store(true, ordering: .releasing); break }
    let credits = CESAdmissionCredits(capacity: slots)
    let configuration = unsafe CESWorkerConfiguration(options: copy options, rio: rio, control: control, failure: failure, credits: credits, workerIndex: index, slotCount: slots, memoryShare: budget)
    do {
      let value = unsafe try CESEngineWorker(configuration: consume configuration)
      unsafe workers.advanced(by: Int(index)).initialize(to: consume value)
    } catch { cesReport(stage: error.stage, error: error.code); failure.failed.store(true, ordering: .releasing); break }
    constructed += 1
    let worker = unsafe workers.advanced(by: Int(index))
    if let error = unsafe cesInitializeWorker(worker) {
      cesReport(stage: error.stage, error: error.code); failure.failed.store(true, ordering: .releasing); break
    }
    let error = unsafe cesStartWorker(worker)
    if unsafe worker.pointee.thread.rawValue != nil { started += 1 }
    if let error { cesReport(stage: error.stage, error: error.code); failure.failed.store(true, ordering: .releasing); break }
  }
  if !failure.failed.load(ordering: .acquiring) {
    let configuration = unsafe CESAcceptorConfiguration(options: copy options, control: control, failure: failure, workers: workers, workerCount: count)
    do {
      let value = unsafe try CESEngineAcceptor(configuration: consume configuration)
      unsafe acceptor.initialize(to: consume value); acceptorConstructed = true
      for i in 0..<constructed { unsafe workers[Int(i)].acceptorAddress = acceptor }
      if let error = unsafe cesInitializeAcceptor(acceptor) {
        if error.code != 0 { cesReport(stage: error.stage, error: error.code) }
        if error.domain != .allocation { statistics.networkErrors &+= 1 }
        failure.failed.store(true, ordering: .releasing)
      } else if let error = unsafe cesStartAcceptor(acceptor) {
        if error.code != 0 { cesReport(stage: error.stage, error: error.code) }
        failure.failed.store(true, ordering: .releasing)
      }
    } catch { cesReport(stage: error.stage, error: error.code); failure.failed.store(true, ordering: .releasing) }
  }
  let start = GetTickCount64()
  let runMilliseconds = UInt64(options.runSeconds) * 1000
  while !failure.failed.load(ordering: .acquiring) && !control.stopRequested.load(ordering: .acquiring) {
    if runMilliseconds != 0 && GetTickCount64() - start >= runMilliseconds {
      control.stopRequested.store(true, ordering: .releasing); break
    }
    Sleep(10)
  }
  // Coordinator barrier: join the whole set before inspecting ANY release invariant.
  if acceptorConstructed {
    if unsafe acceptor.pointee.thread.rawValue != nil { unsafe cesPostAcceptorStop(acceptor) }
    unsafe cesJoinAcceptor(acceptor)
  }
  for i in 0..<constructed {
    let w = unsafe workers.advanced(by: Int(i))
    if unsafe w.pointee.thread.rawValue != nil { unsafe cesPostWorkerAdmissionClosed(w) }
  }
  for i in 0..<constructed {
    let w = unsafe workers.advanced(by: Int(i))
    if unsafe w.pointee.thread.rawValue != nil { unsafe cesPostWorkerStop(w) }
  }
  for i in 0..<constructed { unsafe cesJoinWorker(workers.advanced(by: Int(i))) }
  if acceptorConstructed { unsafe cesRequireAcceptorRelease(acceptor); cesStatisticsAdd(&statistics, unsafe acceptor.pointee.core.statistics) }
  for i in 0..<constructed {
    let w = unsafe workers.advanced(by: Int(i))
    unsafe cesRequireWorkerRelease(w)
    cesStatisticsAdd(&statistics, unsafe w.pointee.engine.statistics)
    snapshots[Int(i)] = unsafe w.pointee.snapshot
  }
  if acceptorConstructed { unsafe cesDestroyAcceptor(acceptor) }
  for i in 0..<constructed { unsafe cesDestroyWorker(workers.advanced(by: Int(i))) }
  for i in 0..<started { cesWriteNotificationDiagnostics(snapshots[Int(i)], protocolKind: .tcp, workerIndex: i) }
  if options.stats { cesPrintFinalStatistics(protocolKind: .tcp, statistics: statistics, elapsedMilliseconds: GetTickCount64() - start, terminalCount: 0, workerCount: started) }
  unsafe workers.deinitialize(count: Int(constructed))
  if acceptorConstructed { unsafe acceptor.deinitialize(count: 1) }
  return failure.failed.load(ordering: .acquiring) ? .network : .success
}
