import Foundation
import WinSDK

// TCP coordinator. Workers own one completion queue, one IOCP, one registered
// arena and one index timer heap each; the acceptor hands accepted RIO sockets to
// them. Stop order is fixed: close admission and join the acceptor, publish the
// admission-closed barrier plus stop to every worker, join them, then release.
private func cesWorkerCount(_ options: borrowing CESOptions) -> UInt32 {
  options.workerCount == 0
    ? min(max(GetActiveProcessorCount(0xffff), 1), 32) : options.workerCount
}
private func cesWorkerStatistics(_ w: UnsafeMutablePointer<CESEngineWorker>)
  -> CESEngineStatistics
{
  unsafe CESEngineStatistics(
    accepted: w.pointee.acceptedCount, completions: w.pointee.completionCount,
    receives: w.pointee.receiveCount, sends: w.pointee.sendCount, bytes: w.pointee.echoedBytes)
}
private func cesRunTCP(
  rio: RIO_EXTENSION_FUNCTION_TABLE, options: borrowing CESOptions, control: CESSharedControl
) -> CESExitCode {
  let count = cesWorkerCount(options)
  let workers = UnsafeMutablePointer<CESEngineWorker>.allocate(capacity: Int(count))
  let acceptor = UnsafeMutablePointer<CESEngineAcceptor>.allocate(capacity: 1)
  let failure = CESFailureFlag()
  var acceptorConstructed = false
  var constructed: UInt32 = 0
  var started: UInt32 = 0
  var statistics = CESEngineStatistics()
  let acceptorConfiguration = unsafe CESAcceptorConfiguration(
    options: copy options, control: control, failure: failure, workers: workers,
    workerCount: count)
  unsafe acceptor.initialize(
    to: CESEngineAcceptor(configuration: consume acceptorConfiguration))
  acceptorConstructed = true
  loop: for index in 0..<count {
    let memoryShare = options.memoryBytes / UInt64(count)
    let possibleSlots =
      UInt64(options.rioBufferBytes) == 0
      ? 0 : memoryShare / UInt64(options.rioBufferBytes)
    let slotCount = cesTCPConnectionCapacity(
      cqCapacity: options.cqCapacity, memorySlots: possibleSlots)
    guard possibleSlots > 0, slotCount > 0 else {
      cesReport(stage: "worker registered arena capacity", error: 8)
      failure.failed.store(true, ordering: .releasing)
      break loop
    }
    let workerConfiguration = unsafe CESWorkerConfiguration(
      options: copy options, rio: rio, control: control, failure: failure, workerIndex: index,
      slotCount: slotCount, memoryShare: memoryShare)
    unsafe workers.advanced(by: Int(index)).initialize(
      to: CESEngineWorker(configuration: consume workerConfiguration))
    constructed += 1
    unsafe workers[Int(index)].acceptorAddress = acceptor
    if unsafe !cesInitializeWorker(workers.advanced(by: Int(index))) {
      failure.failed.store(true, ordering: .releasing)
      break loop
    }
    started += 1
  }
  var acceptorStarted = false
  if !failure.failed.load(ordering: .acquiring) {
    acceptorStarted = unsafe cesInitializeAcceptor(acceptor)
    if !acceptorStarted { failure.failed.store(true, ordering: .releasing) }
  }
  let start = GetTickCount64()
  while !failure.failed.load(ordering: .acquiring)
    && !control.stopRequested.load(ordering: .acquiring)
  {
    if options.runSeconds != 0, GetTickCount64() - start >= UInt64(options.runSeconds) * 1000 {
      control.stopRequested.store(true, ordering: .releasing)
      break
    }
    Sleep(10)
  }
  if acceptorStarted { unsafe cesPostAcceptorStop(acceptor) }
  unsafe cesDestroyAcceptor(acceptor)
  for index in 0..<started {
    unsafe cesPostWorkerAdmissionClosed(workers.advanced(by: Int(index)))
    unsafe cesPostWorkerStop(workers.advanced(by: Int(index)))
  }
  for index in 0..<constructed {
    let w = unsafe workers.advanced(by: Int(index))
    unsafe cesDestroyWorker(w)
    let workerStatistics = unsafe cesWorkerStatistics(w)
    cesStatisticsAdd(&statistics, workerStatistics)
  }
  if options.stats {
    cesPrintFinalStatistics(
      protocolKind: .tcp, statistics: statistics,
      elapsedMilliseconds: GetTickCount64() - start, terminalCount: 0)
  }
  unsafe workers.deinitialize(count: Int(constructed))
  unsafe workers.deallocate()
  if acceptorConstructed {
    unsafe acceptor.deinitialize(count: 1)
    unsafe acceptor.deallocate()
  }
  return failure.failed.load(ordering: .acquiring) ? .network : .success
}
package func cesRunTCPServer(
  rio: RIO_EXTENSION_FUNCTION_TABLE, options: borrowing CESOptions, control: CESSharedControl
) -> CESExitCode {
  cesRunTCP(rio: rio, options: options, control: control)
}
