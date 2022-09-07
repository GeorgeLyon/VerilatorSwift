// swift-tools-version: 5.7
import PackageDescription

let package = Package(
  name: "Verilator",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(
      name: "Verilator",
      targets: ["Verilator"])
  ],
  dependencies: [
    .package(url: "https://github.com/GeorgeLyon/Shwift", from: "1.1.0")
  ],
  targets: [
    .target(
      name: "Verilator",
      dependencies: [
        "Shwift"
      ]),
    .testTarget(
      name: "VerilatorTests",
      dependencies: ["Verilator"],
      resources: [
        .copy("GCD.sv"),
      ]),
  ]
)
