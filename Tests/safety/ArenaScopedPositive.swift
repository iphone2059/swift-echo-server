import CESServerCore
func scoped(_ arena: borrowing CESVirtualArenaOwner) -> UInt8? {
  arena.withBytes(in: 0..<1) { $0[0] }
}
