// Argument contract and checked arithmetic. Every rule mirrors the C++ baseline:
// strict switches, case-insensitive ASCII names, and no positional arguments.
// MARK: - Binary contract (echo-binary-contract-v1)

/// Diagnostic tokens that must follow "Invalid arguments: " on stderr.
package enum CESArgumentToken {
  package static let protocolOption = "protocol-option"
  package static let invalidNumber = "invalid-number"
  package static let outOfRange = "out-of-range"
  package static let unknownSwitch = "unknown-switch"
}

/// Which protocol a switch belongs to; a switch used with the wrong one is a usage error.
package enum CESSwitchScope { case both, tcpOnly, udpOnly }

/// One value switch: its name, the range it accepts and the protocol it applies to.
package struct CESSwitch {
  package let name: String
  package let minimum: UInt64
  package let maximum: UInt64
  package let scope: CESSwitchScope
}

/// The accepted value switches, as value data: one place for names, ranges and protocol scope.
package enum CESSwitchTable {
  package static let valueSwitches: [CESSwitch] = [
    CESSwitch(name: "s", minimum: 1, maximum: 65_535, scope: .both),
    CESSwitch(name: "t", minimum: 1, maximum: UInt64(UInt32.max), scope: .tcpOnly),
    CESSwitch(name: "w", minimum: 1, maximum: UInt64(UInt32.max), scope: .both),
    CESSwitch(name: "b", minimum: 0, maximum: UInt64(Int32.max), scope: .both),
    CESSwitch(name: "k", minimum: 1, maximum: 65_536, scope: .udpOnly),
    CESSwitch(name: "threads", minimum: 1, maximum: 64, scope: .both),
    CESSwitch(name: "rio-buffer", minimum: 512, maximum: 1_048_576, scope: .both),
    CESSwitch(name: "cq", minimum: 64, maximum: 1_048_576, scope: .both),
    CESSwitch(name: "memory", minimum: 1_048_576, maximum: UInt64.max, scope: .both),
  ]

  package static func lookup(_ name: String) -> CESSwitch? {
    valueSwitches.first { $0.name == name }
  }
}

/// The usage text: stdout for a valid /h, stderr for a usage error.
package let cesUsageText = """
Usage: swift-echo-server /p tcp|udp [/s port] [/t seconds] [/w seconds]
       [/b bytes] [/k udp-depth] [/threads workers] [/rio-buffer bytes]
       [/cq capacity] [/memory bytes] [/q] [/stats]
Data I/O is always RIO; CQ notification is always IOCP. No fallback backend exists.

"""
package func cesCheckedProduct(_ a: UInt64, _ b: UInt64) -> UInt64? {
  let (value, overflow) = a.multipliedReportingOverflow(by: b)
  return overflow ? nil : value
}
package func cesCheckedArenaBytes(slots: UInt64, stride: UInt64, memoryLimit: UInt64) -> UInt64? {
  guard let bytes = cesCheckedProduct(slots, stride), bytes <= memoryLimit else { return nil }
  return bytes
}
package func cesTCPConnectionCapacity(cqCapacity: UInt32, memorySlots: UInt64) -> UInt32 {
  let queueSlots = UInt64(cqCapacity / 2)
  let bounded = min(queueSlots, memorySlots)
  return bounded > UInt64(UInt32.max) ? UInt32.max : UInt32(bounded)
}
package func cesAdvanceOffset(total: Int, transferred: Int, offset: inout Int) -> Bool {
  guard transferred > 0, offset >= 0, offset <= total, transferred <= total - offset else {
    return false
  }
  offset += transferred
  return true
}
package func cesNotificationMarkDelivered(_ armed: inout Bool) -> Bool {
  guard armed else { return false }
  armed = false
  return true
}
package func cesNotificationMarkRearmed(_ armed: inout Bool) -> Bool {
  guard !armed else { return false }
  armed = true
  return true
}
private func switchOffset(_ token: [UInt16]) -> Int? {
  guard token.count >= 2, token[0] == 47 || token[0] == 45 else { return nil }
  let i = token.count > 2 && token[0] == 45 && token[1] == 45 ? 2 : 1
  return (65...90).contains(token[i]) || (97...122).contains(token[i]) ? i : nil
}
private func asciiLower(_ value: ArraySlice<UInt16>) -> String {
  String(decoding: value.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF16.self)
}
private func numeric(_ value: [UInt16]) throws(CESArgumentError) -> UInt64 {
  var result: UInt64 = 0
  for char in value {
    guard (48...57).contains(char), let product = cesCheckedProduct(result, 10) else {
      throw CESArgumentError(message: CESArgumentToken.invalidNumber)
    }
    let (next, overflow) = product.addingReportingOverflow(UInt64(char - 48))
    guard !overflow else {
      throw CESArgumentError(message: CESArgumentToken.invalidNumber)
    }
    result = next
  }
  return result
}
package func cesParseOptions(_ arguments: [[UInt16]]) throws(CESArgumentError) -> CESOptions {
  guard !arguments.isEmpty else { throw CESArgumentError(message: "invalid parser arguments") }
  var o = CESOptions()
  var sawTimeout = false
  var sawUDPDepth = false
  var sawRIOBuffer = false
  var i = 1
  while i < arguments.count {
    let token = arguments[i]
    i += 1
    guard let offset = switchOffset(token) else {
      throw CESArgumentError(message: "unexpected-target")
    }
    let equal = token[offset...].firstIndex(of: 61)
    let name = asciiLower(token[offset..<(equal ?? token.count)])
    let inline = equal.map { Array(token[($0 + 1)...]) }
    if let inline, inline.isEmpty {
      throw CESArgumentError(message: "switch requires a non-empty inline value")
    }
    if ["q", "quiet", "stats", "h", "help"].contains(name) {
      guard inline == nil else {
        throw CESArgumentError(message: "flag switch does not accept a value")
      }
      switch name {
      case "q", "quiet": o.quiet = true
      case "stats": o.stats = true
      default: o.help = true
      }
      continue
    }
    guard
      ["p", "s", "t", "w", "b", "k", "threads", "rio-buffer", "cq", "memory"].contains(name)
    else { throw CESArgumentError(message: CESArgumentToken.unknownSwitch) }
    let value: [UInt16]
    if let inline {
      value = inline
    } else {
      guard i < arguments.count, !arguments[i].isEmpty, switchOffset(arguments[i]) == nil else {
        throw CESArgumentError(message: "switch requires a non-empty value")
      }
      value = arguments[i]
      i += 1
    }
    if name == "p" {
      switch asciiLower(value[...]) {
      case "tcp": o.protocolKind = .tcp
      case "udp": o.protocolKind = .udp
      default: throw CESArgumentError(message: "/p requires tcp or udp")
      }
      continue
    }
    let n = try numeric(value)
    let range: ClosedRange<UInt64>
    switch name {
    case "s": range = 1...65_535
    case "t", "w": range = 1...UInt64(UInt32.max)
    case "b": range = 0...UInt64(Int32.max)
    case "k": range = 1...65_536
    case "threads": range = 1...64
    case "rio-buffer": range = 512...1_048_576
    case "cq": range = 64...1_048_576
    default: range = 1_048_576...UInt64.max
    }
    guard range.contains(n) else {
      throw CESArgumentError(message: CESArgumentToken.outOfRange)
    }
    switch name {
    case "s": o.port = UInt16(n)
    case "t":
      o.timeoutSeconds = UInt32(n)
      sawTimeout = true
    case "w": o.runSeconds = UInt32(n)
    case "b": o.socketBufferBytes = UInt32(n)
    case "k":
      o.udpDepth = UInt32(n)
      sawUDPDepth = true
    case "threads": o.workerCount = UInt32(n)
    case "rio-buffer":
      o.rioBufferBytes = UInt32(n)
      sawRIOBuffer = true
    case "cq": o.cqCapacity = UInt32(n)
    default: o.memoryBytes = n
    }
  }
  if o.protocolKind == .tcp && sawUDPDepth {
    throw CESArgumentError(message: CESArgumentToken.protocolOption)
  }
  if o.protocolKind == .udp && sawTimeout {
    throw CESArgumentError(message: CESArgumentToken.protocolOption)
  }
  if o.help { return o }
  guard o.protocolKind != .none else {
    throw CESArgumentError(message: "missing-protocol")
  }
  if o.protocolKind == .udp {
    if !sawRIOBuffer {
      o.rioBufferBytes = UInt32(CESConstants.maximumUDPPayloadBytes)
    } else if UInt64(o.rioBufferBytes) < CESConstants.maximumUDPPayloadBytes {
      throw CESArgumentError(message: "UDP /rio-buffer must be at least 65507 bytes")
    }
  }
  return o
}