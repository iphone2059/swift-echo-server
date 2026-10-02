import CESServerCore
func escaped(_ arena: borrowing CESVirtualArenaOwner) -> Span<UInt8> {
  arena.withBytes(in: 0..<1) { $0 }!
}
