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
  let options = try cesParse("--p=UDP", "-S", "7000", "--THREADS=4", "/Rio-Buffer", "65507")
  #expect(options.protocolKind == .udp)
  #expect(options.port == 7000)
  #expect(options.workerCount == 4)
  #expect(options.rioBufferBytes == 65_507)
}

@Test func flagsDoNotAcceptValues() {
  #expect(cesMessage("/p", "tcp", "/stats=1") == "flag switch does not accept a value")
  #expect(cesMessage("/p", "tcp", "/q=") == "switch requires a non-empty inline value")
  #expect(cesMessage("/p", "tcp", "/s=") == "switch requires a non-empty inline value")
  #expect(cesMessage("/p", "tcp", "/s") == "switch requires a non-empty value")
  #expect(cesMessage("/p", "tcp", "/s", "/stats") == "switch requires a non-empty value")
  #expect(cesMessage("/p", "tcp", "/unknown") == "unknown switch")
  #expect(cesMessage("/p", "tcp", "positional") == "server does not accept positional arguments")
  #expect(cesMessage("/p", "sctp") == "/p requires tcp or udp")
  #expect(cesMessage("/s", "7000") == "missing /p tcp or /p udp")
}

@Test func valueRangesAreStrict() {
  #expect(cesMessage("/p", "tcp", "/s", "0") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/s", "65536") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/threads", "0") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/threads", "65") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/cq", "63") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/cq", "1048577") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/rio-buffer", "511") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/memory", "1048575") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/t", "0") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/w", "4294967296") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/b", "2147483648") == "unknown switch or value outside its valid range")
  #expect(cesMessage("/p", "tcp", "/s", "7000x") == "numeric switch has an invalid value")
}

@Test func protocolSpecificSwitchesAreRejected() {
  #expect(cesMessage("/p", "tcp", "/k", "8") == "/k is available only for UDP")
  #expect(cesMessage("/p", "udp", "/t", "5") == "/t is available only for TCP")
  #expect(cesMessage("/p", "tcp", "/k=8") == "/k is available only for UDP")
  let options = try? cesParse("/p", "tcp", "/t", "5", "/s", "7000")
  #expect(options?.timeoutSeconds == 5)
}

@Test func maximumValuesAreAccepted() throws {
  let options = try cesParse(
    "/p", "tcp", "/s", "65535", "/t", "4294967295", "/w", "4294967295", "/b", "2147483647",
    "/threads", "64", "/rio-buffer", "1048576", "/cq", "1048576", "/memory", "1048576")
  #expect(options.port == 65_535)
  #expect(options.timeoutSeconds == UInt32.max)
  #expect(options.runSeconds == UInt32.max)
  #expect(options.socketBufferBytes == 2_147_483_647)
  #expect(options.workerCount == 64)
  #expect(options.rioBufferBytes == 1_048_576)
  #expect(options.cqCapacity == 1_048_576)
  #expect(options.memoryBytes == 1_048_576)
}

@Test func helpNeverMasksMalformedArguments() {
  let help = try? cesParse("/h")
  #expect(help?.help == true)
  let long = try? cesParse("--help")
  #expect(long?.help == true)
  #expect(cesMessage("/p", "tcp", "/h", "/nonsense") == "unknown switch")
  #expect(cesMessage("/h", "/s", "0") == "unknown switch or value outside its valid range")
  // /h returns before the semantic checks, exactly like the C++ baseline.
  #expect(cesMessage("/h", "/s", "7000") == nil)
  let tolerated = try? cesParse("/h", "/p", "tcp")
  #expect(tolerated?.help == true)
}

@Test func parserRejectsAnEmptyArgumentVector() {
  #expect(throws: CESArgumentError.self) { try cesParseOptions([]) }
}
