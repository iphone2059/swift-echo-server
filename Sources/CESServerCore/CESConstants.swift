import WinSDK

// Fixed protocol constants; every value mirrors the C++ baseline contract.
package enum CESConstants {
  package static let defaultPort: UInt16 = 7
  package static let defaultTCPTimeoutSeconds: UInt32 = 300
  package static let defaultUDPDepth: UInt32 = 256
  package static let defaultRIOBufferBytes: UInt32 = 16_384
  package static let defaultCQCapacity: UInt32 = 4_096
  package static let defaultMemoryBytes: UInt64 = 1_073_741_824
  package static let maximumUDPPayloadBytes: UInt64 = 65_507
  package static let completionBatchSize = 256
  package static let acceptsPerWorker: UInt32 = 32
  package static let maximumAccepts: UInt32 = 1_024
  // AcceptEx requires a SOCKADDR_STORAGE plus 16 bytes of padding per address.
  package static let acceptAddressBytes = MemoryLayout<SOCKADDR_STORAGE>.size + 16
  package static let acceptBufferBytes = (MemoryLayout<SOCKADDR_STORAGE>.size + 16) * 2
  package static let udpAddressBytes = MemoryLayout<SOCKADDR_STORAGE>.size + 16
  package static let stopKey: UInt = 1
  package static let admissionClosedKey: UInt = 2
}
