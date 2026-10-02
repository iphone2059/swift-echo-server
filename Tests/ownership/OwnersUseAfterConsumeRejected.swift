import CESServerCore

func take(_ value: consuming CESHandleOwner) {}
func invalid() {
  let owner = CESHandleOwner()
  take(consume owner)
  _ = owner.rawValue
}
