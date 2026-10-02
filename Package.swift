// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "swift-echo-server",
  products: [
    .executable(name: "swift-echo-server", targets: ["swift_echo_server"])
  ],
  targets: [
    .target(
      name: "CESServerCore",
      swiftSettings: [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)],
      linkerSettings: [.linkedLibrary("Ws2_32")]),
    .executableTarget(
      name: "swift_echo_server", dependencies: ["CESServerCore"],
      swiftSettings: [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)]),
    .testTarget(name: "swift_echo_serverTests", dependencies: ["CESServerCore"]),
  ],
  swiftLanguageModes: [.v6]
)
