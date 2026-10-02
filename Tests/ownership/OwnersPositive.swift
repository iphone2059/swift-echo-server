import CESServerCore

func take(_ value: consuming CESSocketOwner) {}
func valid() {
  var owners = UniqueArray<CESSocketOwner>()
  owners.append(CESSocketOwner())
  owners[0].reset()
  let owner = CESHandleOwner()
  let moved = consume owner
  _ = moved.rawValue
  take(CESSocketOwner())
}
