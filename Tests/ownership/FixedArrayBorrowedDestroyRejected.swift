import CESServerCore
func consumeStorage(_ value: consuming CESFixedArray<UInt8>) {}
func invalid(_ value: borrowing CESFixedArray<UInt8>) { consumeStorage(consume value) }
