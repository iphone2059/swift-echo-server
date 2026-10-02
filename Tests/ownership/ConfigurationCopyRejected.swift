import CESServerCore
func consumeConfiguration(_ configuration: consuming CESWorkerConfiguration) {}
func duplicated(_ configuration: consuming CESWorkerConfiguration) {
  unsafe consumeConfiguration(copy configuration)
  unsafe consumeConfiguration(configuration)
}
