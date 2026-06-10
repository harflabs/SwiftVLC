// swift-tools-version: 6.3

import PackageDescription

/// The dynamic intermediary of the layered-app consumption fixture:
/// MediaCore is the single owner of the SwiftVLC dependency and is built
/// as a dynamic framework, so the libvlc static archive is linked into it
/// exactly once. The wrapper lives in its own package because static
/// feature targets in the *same* package would depend on the MediaCore
/// target directly and Xcode cannot build one package target both
/// statically and dynamically; consuming the dynamic *product* across a
/// package boundary links it dynamically.
let package = Package(
  name: "MediaCoreKit",
  platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "MediaCore", type: .dynamic, targets: ["MediaCore"])
  ],
  dependencies: [
    .package(path: "../../..")
  ],
  targets: [
    .target(
      name: "MediaCore",
      dependencies: [.product(name: "SwiftVLC", package: "SwiftVLC")]
    )
  ]
)
