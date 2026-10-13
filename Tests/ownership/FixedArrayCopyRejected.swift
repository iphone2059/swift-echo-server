import CESServerCore
func consumeStorage(_ value: consuming CESFixedArray<UInt8>) {}
func copied(_ value: consuming CESFixedArray<UInt8>) {
  consumeStorage(copy value)
  consumeStorage(value)
}
