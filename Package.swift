// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SwiftVLC",
  platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
  products: [
    .library(name: "SwiftVLC", targets: ["SwiftVLC"])
  ],
  targets: [
    .binaryTarget(
      name: "libvlc",
      url: "https://github.com/harflabs/SwiftVLC/releases/download/v0.1.0/libvlc.xcframework.zip",
      checksum: "9743f87f71f265ec431a588981bb78fc23423f61ff084c280327c4d63df52905"
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
      swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
      name: "SwiftVLCTests",
      dependencies: ["SwiftVLC"],
      resources: [.copy("Fixtures")]
    )
  ]
)
