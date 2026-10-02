package enum CESProtocol: UInt8, Sendable { case none, tcp, udp }
package enum CESExitCode: Int32, Sendable {
  case success, usage, network
  // Declared for parity with the C++ baseline exit-code contract; the server never
  // classifies a run as an echo failure (only the client does).
  case echoFailure
  case internalFailure
}
package struct CESArgumentError: Error, Equatable { package let message: String }
// Defaults live in CESConstants so the parser contract has a single source of truth.
package struct CESOptions: Sendable {
  package init() {}
  package var protocolKind: CESProtocol = .none
  package var port: UInt16 = CESConstants.defaultPort
  package var timeoutSeconds: UInt32 = CESConstants.defaultTCPTimeoutSeconds
  package var runSeconds: UInt32 = 0
  package var socketBufferBytes: UInt32 = 0
  package var udpDepth: UInt32 = CESConstants.defaultUDPDepth
  package var workerCount: UInt32 = 0
  package var rioBufferBytes: UInt32 = CESConstants.defaultRIOBufferBytes
  package var cqCapacity: UInt32 = CESConstants.defaultCQCapacity
  package var memoryBytes: UInt64 = CESConstants.defaultMemoryBytes
  // Accepted for CLI parity with the baseline, which also never reads it: the server
  // prints nothing outside /stats, so /q cannot suppress anything. Kept so that a
  // scripted command line shared with the C++ server keeps parsing.
  package var quiet = false
  package var stats = false
  package var help = false
}
