import CESServerCore

func take(_ value: consuming CESHandleOwner) {}
func invalid(_ owner: borrowing CESHandleOwner) { take(consume owner) }
