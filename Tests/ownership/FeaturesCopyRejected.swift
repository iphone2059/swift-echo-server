struct FeatureCell: ~Copyable { var value: UInt64 }
func take(_ value: consuming FeatureCell) {}
func ownershipNegative() {
  let value = FeatureCell(value: 7)
  take(consume value)
  take(consume value)
}
