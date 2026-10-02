func invalid() -> Span<UInt8> {
  let source: [UInt8] = [1, 2, 3]
  return source.span
}
