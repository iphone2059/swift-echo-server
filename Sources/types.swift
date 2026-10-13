// Shared native-independent vocabulary. Failure payloads and completion identity
// survive transport normalization; cancellation is never a completion.
package enum CESProtocol: UInt8, Sendable { case none, tcp, udp }
package enum CESExitCode: Int32, Sendable { case success, usage, network, echoFailure, internalFailure }
package struct CESArgumentError: Error, Equatable { package let message: String }
package enum CESConstants {
  package static let defaultPort: UInt16 = 7
  package static let defaultTCPTimeoutSeconds: UInt32 = 300
  package static let defaultUDPDepth: UInt32 = 256
  package static let defaultRIOBufferBytes: UInt32 = 16384
  package static let defaultCQCapacity: UInt32 = 4096
  package static let defaultMemoryBytes: UInt64 = 1073741824
  package static let maximumUDPPayloadBytes: UInt64 = 65507
  package static let completionBatchSize = 256
  package static let completionDrainBatches = 64
  package static let maximumWorkers: UInt32 = 64
  package static let acceptAddressBytes = 144
  package static let acceptBufferBytes = 288
  package static let udpAddressBytes = 144
  package static let stopKey: UInt = 1
  package static let admissionClosedKey: UInt = 2
  package static let drainGraceMilliseconds: UInt64 = 5000
  package static let inlineAcceptRetries = 4
}
package struct CESOptions: Sendable {
  package init() {}
  package var protocolKind: CESProtocol = .none
  package var port = CESConstants.defaultPort
  package var timeoutSeconds = CESConstants.defaultTCPTimeoutSeconds
  package var runSeconds: UInt32 = 0
  package var socketBufferBytes: UInt32 = 0
  package var udpDepth = CESConstants.defaultUDPDepth
  package var workerCount: UInt32 = 0
  package var rioBufferBytes = CESConstants.defaultRIOBufferBytes
  package var cqCapacity = CESConstants.defaultCQCapacity
  package var memoryBytes = CESConstants.defaultMemoryBytes
  package var quiet = false
  package var stats = false
  package var help = false
}
package enum CESFailureClass: Equatable, Sendable { case network, invariant, drainTimeout }
package enum CESFailureDomain: Equatable, Sendable { case win32, winsock, allocation, invariant }
package struct CESFailure: Error, Equatable, Sendable {
  package var classification: CESFailureClass = .network
  package var domain: CESFailureDomain = .winsock
  package let stage: String
  package let code: Int32
  package static func invariant(_ stage: String) -> CESFailure {
    CESFailure(classification: .invariant, domain: .invariant, stage: stage, code: 13)
  }
  package static func allocation(_ stage: String) -> CESFailure {
    CESFailure(domain: .allocation, stage: stage, code: 8)
  }
  package static func timeout(_ stage: String) -> CESFailure {
    CESFailure(classification: .drainTimeout, domain: .win32, stage: stage, code: 1460)
  }
}
package enum CESWorkerPhase: UInt8 { case starting, running, quiescing, admissionClosed, draining, stopped }
package struct CESWorkerLifecycle {
  package var phase: CESWorkerPhase = .starting
  package var activeConnections: UInt32 = 0
  package var pendingHandoffs: UInt32 = 0
  package var notificationArmed = false
  package var rioOutstanding: UInt32 = 0
}
package func cesWorkerMayExit(_ v: CESWorkerLifecycle) -> Bool {
  v.phase.rawValue >= CESWorkerPhase.admissionClosed.rawValue && v.activeConnections == 0
    && v.pendingHandoffs == 0 && v.rioOutstanding == 0
}
package enum CESUDPPhase: UInt8 { case running, draining, stopped }
package func cesUdpMayRelease(phase: CESUDPPhase, outstanding: UInt32) -> Bool {
  phase == .stopped && outstanding == 0
}
package enum CESEngineOperation: UInt8, Equatable { case receive, send }
package struct CESCompletion: Equatable {
  package let index: UInt32
  package let operation: CESEngineOperation
  package let status: Int32
  package let bytes: UInt32
}
package enum CESEvent: Equatable {
  case completion(CESCompletion), postFailed(index: UInt32, failure: CESFailure)
  case stop, admissionClosed, generationDrained
}
package struct CESEngineStatistics {
  package var accepted: UInt64 = 0
  package var completions: UInt64 = 0
  package var receives: UInt64 = 0
  package var sends: UInt64 = 0
  package var bytes: UInt64 = 0
  package var receivedBytes: UInt64 = 0
  package var sentBytes: UInt64 = 0
  package var networkErrors: UInt64 = 0
  package var rejected: UInt64 = 0
  package mutating func record(_ c: CESCompletion, closing: Bool) {
    completions &+= 1
    if c.status == 0 {
      if c.operation == .receive { receives &+= 1; receivedBytes &+= UInt64(c.bytes) }
      else { sends &+= 1; sentBytes &+= UInt64(c.bytes); bytes &+= UInt64(c.bytes) }
    } else if !closing { networkErrors &+= 1 }
  }
}
package func cesStatisticsAdd(_ a: inout CESEngineStatistics, _ b: borrowing CESEngineStatistics) {
  a.accepted &+= b.accepted; a.completions &+= b.completions
  a.receives &+= b.receives; a.sends &+= b.sends; a.bytes &+= b.bytes
  a.receivedBytes &+= b.receivedBytes; a.sentBytes &+= b.sentBytes
  a.networkErrors &+= b.networkErrors; a.rejected &+= b.rejected
}
package struct CESNotifySnapshot {
  package var arms: UInt64 = 0
  package var deliveries: UInt64 = 0
  package var timeoutWakeups: UInt64 = 0
  package var valid: Bool { timeoutWakeups == 0 && arms >= deliveries && arms - deliveries <= 1 }
}
package enum CESAction: Equatable {
  case receive(index: UInt32, deadline: UInt64)
  case send(index: UInt32, offset: UInt32, length: UInt32, deadline: UInt64)
  case close(index: UInt32), release(index: UInt32)
  package var index: UInt32 {
    switch self {
    case .receive(let i, _), .send(let i, _, _, _), .close(let i), .release(let i): return i
    }
  }
}
