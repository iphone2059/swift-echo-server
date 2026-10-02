struct FeatureCell: ~Copyable { var value: UInt64 }
struct Wrapper: ~Copyable {
  var stored: FeatureCell
  var element: FeatureCell {
    borrow { stored }
    mutate { &stored }
  }
}
func ownershipPositive() -> UInt64 {
  var wrapper = Wrapper(stored: FeatureCell(value: 1))
  wrapper.element.value = 2
  var values = UniqueArray<FeatureCell>()
  values.append(FeatureCell(value: wrapper.element.value))
  let box = UniqueBox(FeatureCell(value: 3))
  return values[0].value + box.value.value
}
