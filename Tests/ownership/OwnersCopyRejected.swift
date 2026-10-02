import CESServerCore

func take(_ value: consuming CESSocketOwner) {}
func invalid() {
  let owner = CESSocketOwner()
  take(consume owner)
  take(consume owner)
}
