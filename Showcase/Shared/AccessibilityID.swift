import Foundation

/// Identifiers used by XCUITest to locate SwiftUI controls.
///
/// Compiled into both the showcase app target (where each constant is applied
/// via `.accessibilityIdentifier(...)`) and the UI test target (where it is
/// used to query the resulting `XCUIElement`s). Renaming a constant here is a
/// compile-time break on both sides, not a runtime test failure.
enum AccessibilityID {
  enum Root {
    static let navigationStack = "root.nav"
    static func sectionLink(_ title: String) -> String {
      "root.link.\(title)"
    }
  }

  enum SimplePlayback {
    static let videoView = "sp.videoView"
    static let playPauseButton = "sp.playPause"
    static let currentTime = "sp.currentTime"
    static let duration = "sp.duration"
  }

  enum PlayerState {
    static let videoView = "ps.videoView"
    static let playPauseButton = "ps.playPause"
    static let stateLabel = "ps.state"
    static let seekableLabel = "ps.seekable"
    static let pausableLabel = "ps.pausable"
  }
}
