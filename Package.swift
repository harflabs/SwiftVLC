// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "SwiftVLC",
  platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18), .macCatalyst(.v18)],
  products: [
    .library(name: "SwiftVLC", targets: ["SwiftVLC"])
  ],
  targets: [
    .binaryTarget(
      name: "libvlc",
      url: "https://github.com/harflabs/SwiftVLC/releases/download/v0.3.0/libvlc.xcframework.zip",
      checksum: "917bfa0881ae264652a51d11c99a45af816ec05e031af55dff19af5d5aedb34f"
    ),
    .target(
      name: "CLibVLC",
      dependencies: ["libvlc"],
      publicHeadersPath: "include",
      linkerSettings: [
        // System frameworks required by libVLC
        .linkedFramework("AudioToolbox"),
        .linkedFramework("AudioUnit", .when(platforms: [.macOS])),
        .linkedFramework("AVFoundation"),
        .linkedFramework("AVKit"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("CoreFoundation"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreImage"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreServices"),
        .linkedFramework("CoreText"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("Foundation"),
        .linkedFramework("IOKit", .when(platforms: [.macOS])),
        .linkedFramework("IOSurface"),
        .linkedFramework("OpenGL", .when(platforms: [.macOS])),
        .linkedFramework("OpenGLES", .when(platforms: [.iOS, .tvOS])),
        .linkedFramework("QuartzCore"),
        .linkedFramework("Security"),
        .linkedFramework("SystemConfiguration"),
        .linkedFramework("VideoToolbox"),

        // System libraries required by libVLC and its contribs
        .linkedLibrary("bz2"),
        .linkedLibrary("c++"),
        .linkedLibrary("iconv"),
        .linkedLibrary("resolv"),
        .linkedLibrary("sqlite3"),
        .linkedLibrary("xml2"),
        .linkedLibrary("z")
      ]
    ),
    .target(
      name: "SwiftVLC",
      dependencies: ["CLibVLC"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        // Upcoming features that become default in Swift 7 — opt-in early
        // to keep the codebase forward-compatible and catch issues now.
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"), // SE-0461
        .enableUpcomingFeature("MemberImportVisibility"), // SE-0444
        .enableUpcomingFeature("InferIsolatedConformances"), // SE-0449
        .enableUpcomingFeature("ImmutableWeakCaptures"), // SE-0481
        // Experimental: @_lifetime(borrow …) for ~Escapable overlays
        // (Marquee / Logo / VideoAdjustments).
        .enableExperimentalFeature("Lifetimes")
      ]
    ),
    .testTarget(
      name: "SwiftVLCTests",
      dependencies: ["SwiftVLC"],
      resources: [.copy("Fixtures")],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("MemberImportVisibility")
      ]
    )
  ]
)
