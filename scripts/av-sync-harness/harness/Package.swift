// swift-tools-version: 6.0
import PackageDescription

// Built by ../prepare.sh, which places a SwiftVLC copy exporting CLibVLC and
// linked against the engine under test at ../swiftvlc.
let package = Package(
  name: "avharness",
  platforms: [.macOS(.v15)],
  dependencies: [.package(path: "../swiftvlc")],
  targets: [
    .executableTarget(
      name: "avh",
      dependencies: [
        .product(name: "SwiftVLC", package: "swiftvlc"),
        .product(name: "CLibVLC", package: "swiftvlc")
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
