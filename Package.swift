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
      checksum: "cc1f21b154d0ea6ddf0dc87cd543bb933b19c369878fbf5143b725ea00f6f136"
    )
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
