// swift-tools-version: 6.3

import PackageDescription

/// Static feature layer of the layered-app consumption fixture. FeatureA
/// and FeatureB consume SwiftVLC types only through MediaCoreKit's dynamic
/// MediaCore product — they never declare their own SwiftVLC dependency —
/// so linking them into the host app cannot duplicate the libvlc static
/// archive.
let package = Package(
  name: "MediaKit",
  platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "FeatureA", type: .static, targets: ["FeatureA"]),
    .library(name: "FeatureB", type: .static, targets: ["FeatureB"])
  ],
  dependencies: [
    .package(path: "../MediaCoreKit")
  ],
  targets: [
    .target(
      name: "FeatureA",
      dependencies: [.product(name: "MediaCore", package: "MediaCoreKit")]
    ),
    .target(
      name: "FeatureB",
      dependencies: [.product(name: "MediaCore", package: "MediaCoreKit")]
    )
  ]
)
