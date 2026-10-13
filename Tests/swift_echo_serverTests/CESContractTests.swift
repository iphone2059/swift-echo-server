import Testing

@testable import CESServerCore

private func cesArguments(_ values: [String]) -> [[UInt16]] {
  [Array("swift-echo-server".utf16)] + values.map { Array($0.utf16) }
}
private func cesParse(_ values: String...) throws -> CESOptions {
  try cesParseOptions(cesArguments(Array(values)))
}
private func cesMessage(_ values: String...) -> String? {
  do {
    _ = try cesParseOptions(cesArguments(Array(values)))
    return nil
  } catch {
    return error.message
  }
}

@Test func defaultOptionsMatchTheBaseline() throws {
  let options = try cesParse("/p", "tcp", "/s", "7000")
  #expect(options.protocolKind == .tcp)
  #expect(options.port == 7000)
  #expect(options.timeoutSeconds == 300)
  #expect(options.runSeconds == 0)
  #expect(options.socketBufferBytes == 0)
  #expect(options.udpDepth == 256)
  #expect(options.workerCount == 0)
  #expect(options.rioBufferBytes == 16_384)
  #expect(options.cqCapacity == 4_096)
  #expect(options.memoryBytes == 1_073_741_824)
  #expect(!options.quiet && !options.stats && !options.help)
}

@Test func udpDefaultsToTheMaximumPayloadBuffer() throws {
  let options = try cesParse("/p", "udp")
  #expect(options.rioBufferBytes == 65_507)
  #expect(options.udpDepth == 256)
  #expect(throws: CESArgumentError.self) { try cesParse("/p", "udp", "/rio-buffer", "65000") }
  let explicit = try cesParse("/p", "udp", "/rio-buffer", "65507")
  #expect(explicit.rioBufferBytes == 65_507)
}

@Test func switchFormsAndCaseAreAccepted() throws {
  let options = try cesParse("--p=UDP", "-S", "7000", "--THREADS=1", "/Rio-Buffer", "65507")
  #expect(options.protocolKind == .udp)
  #expect(options.port == 7000)
  #expect(options.workerCount == 1)
  #expect(options.rioBufferBytes == 65_507)
}

@Test func flagsDoNotAcceptValues() {
  #expect(cesMessage("/p", "tcp", "/stats=1") == "unexpected-value")
  #expect(cesMessage("/p", "tcp", "/q=") == "unexpected-value")
  #expect(cesMessage("/p", "tcp", "/s=") == "missing-value")
  #expect(cesMessage("/p", "tcp", "/s") == "missing-value")
  #expect(cesMessage("/p", "tcp", "/s", "/stats") == "missing-value")
  #expect(cesMessage("/p", "tcp", "/unknown") == "unknown-switch")
  #expect(cesMessage("/p", "tcp", "positional") == "unexpected-target")
  #expect(cesMessage("/p", "sctp") == "out-of-range")
  #expect(cesMessage("/s", "7000") == "missing-protocol")
}

@Test func valueRangesAreStrict() {
  #expect(cesMessage("/p", "tcp", "/s", "0") == "out-of-range")
  #expect(cesMessage("/p", "tcp", "/s", "65536") == "out-of-range")
  #expect(cesMessage("/p", "tcp", "/threads", "0") == nil)
  #expect(cesMessage("/p", "tcp", "/threads", "65") == "out-of-range")
  #expect(cesMessage("/p", "tcp", "/cq", "63") == "out-of-range")
  #expect(cesMessage("/p", "tcp", "/cq", "1048577") == "out-of-range")
  #expect(cesMessage("/p", "tcp", "/rio-buffer", "511") == "out-of-range")
  #expect(cesMessage("/p", "tcp", "/memory", "1048575") == "out-of-range")
  #expect(cesMessage("/p", "tcp", "/t", "0") == "out-of-range")
  #expect(cesMessage("/p", "tcp", "/w", "4294967296") == "out-of-range")
  #expect(cesMessage("/p", "tcp", "/b", "2147483648") == "out-of-range")
  #expect(cesMessage("/p", "tcp", "/s", "7000x") == "invalid-number")
}

@Test func protocolSpecificSwitchesAreRejected() {
  #expect(cesMessage("/p", "tcp", "/k", "8") == "protocol-option")
  #expect(cesMessage("/p", "udp", "/t", "5") == "protocol-option")
  #expect(cesMessage("/p", "tcp", "/k=8") == "protocol-option")
  let options = try? cesParse("/p", "tcp", "/t", "5", "/s", "7000")
  #expect(options?.timeoutSeconds == 5)
}

@Test func maximumValuesAreAccepted() throws {
  let options = try cesParse(
    "/p", "tcp", "/s", "65535", "/t", "4294967295", "/w", "4294967295", "/b", "2147483647",
    "/threads", "64", "/rio-buffer", "1048576", "/cq", "1048576", "/memory", "67108864")
  #expect(options.port == 65_535)
  #expect(options.timeoutSeconds == UInt32.max)
  #expect(options.runSeconds == UInt32.max)
  #expect(options.socketBufferBytes == 2_147_483_647)
  #expect(options.workerCount == 64)
  #expect(options.rioBufferBytes == 1_048_576)
  #expect(options.cqCapacity == 1_048_576)
  #expect(options.memoryBytes == 67_108_864)
}

@Test func helpNeverMasksMalformedArguments() {
  let help = try? cesParse("/h")
  #expect(help?.help == true)
  let long = try? cesParse("--help")
  #expect(long?.help == true)
  #expect(cesMessage("/p", "tcp", "/h", "/nonsense") == "unknown-switch")
  #expect(cesMessage("/h", "/s", "0") == "out-of-range")
  // Help skips the mandatory protocol only; semantic and capacity checks run first.
  #expect(cesMessage("/h", "/s", "7000") == nil)
  let tolerated = try? cesParse("/h", "/p", "tcp")
  #expect(tolerated?.help == true)
}

@Test func parserRejectsAnEmptyArgumentVector() {
  #expect(throws: CESArgumentError.self) { try cesParseOptions([]) }
}

// Current three reference servers agree on these semantic checks. They replace
// the old pre-refactor Swift assertions, not an implementation-specific result.
@Test func helpDoesNotMaskCapacityOrProtocolChecks() {
  #expect(cesMessage("/h", "/p", "udp", "/threads", "4") == "protocol-option")
  #expect(cesMessage("/h", "/p", "udp", "/k", "33", "/cq", "64") == "cq-capacity")
  #expect(cesMessage("/h", "/p", "tcp", "/threads", "64", "/rio-buffer", "1048576", "/memory", "1048576") == "memory-capacity")
  #expect(cesMessage("/p", "tcp", "/w", "0", "/threads", "0") == nil)
  #expect(cesMessage("/p", "udp", "/threads", "0") == nil)
}

@Test func parserPreservesInvalidUtf16Diagnostic() {
  var args = cesArguments(["/p", "tcp", "/s"])
  args.append([0xd800])
  do { _ = try cesParseOptions(args); Issue.record("invalid UTF16 accepted") }
  catch { #expect(error.message == "invalid-utf16") }
}
