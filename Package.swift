// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "swift-echo-server",
  products: [
    .executable(name: "swift-echo-server", targets: ["swift_echo_server"]),
    .executable(name: "swift-echo-server-fault-driver", targets: ["CESFaultDriver"])
  ],
  targets: [
    .target(
      name: "CESServerCore", path: "Sources", exclude: ["main.swift"],
      sources: ["contract.swift", "types.swift", "native.swift", "internal.swift", "engine.swift", "server.swift"],
      swiftSettings: [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)],
      linkerSettings: [.linkedLibrary("Ws2_32")]),
    .executableTarget(
      name: "swift_echo_server", dependencies: ["CESServerCore"], path: "Sources",
      exclude: ["contract.swift", "types.swift", "native.swift", "internal.swift", "engine.swift", "server.swift"],
      sources: ["main.swift"],
      swiftSettings: [.strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error)]),
    .testTarget(name: "swift_echo_serverTests", dependencies: ["CESServerCore"]),
    .executableTarget(name: "CESFaultDriver", dependencies: ["CESServerCore"], path: "Tests/CESFaultDriver"),
  ],
  swiftLanguageModes: [.v6]
)
