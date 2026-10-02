import CESServerCore
func invalidated(_ arena: inout CESVirtualArenaOwner) -> UInt8? {
  arena.withBytes(in: 0..<1) { bytes in
    unsafe arena.reset()
    return bytes[0]
  }
}
