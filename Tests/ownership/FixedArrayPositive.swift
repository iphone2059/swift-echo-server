import CESServerCore

func boundedOwner() throws {
  var values = try CESFixedArray(count: 2, repeating: UInt8(0))
  values[0] = 1
  let moved = consume values
  _ = moved[0]
}
