import SwiftUI

enum ShowcaseItem: String, CaseIterable, Identifiable {
  case polishedPlayer
  case pictureInPicture
  case audioPlayer
  case playlist
  case snapshotAndLoop
  case debugConsole

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .polishedPlayer: "Polished Player"
    case .pictureInPicture: "Picture in Picture"
    case .audioPlayer: "Audio Player"
    case .playlist: "Playlist"
    case .snapshotAndLoop: "Snapshot & A-B Loop"
    case .debugConsole: "Debug Console"
    }
  }

  var subtitle: String {
    switch self {
    case .polishedPlayer: "Production-quality video player"
    case .pictureInPicture: "PiP without AVPlayer"
    case .audioPlayer: "Music playback with equalizer"
    case .playlist: "Multi-track queue"
    case .snapshotAndLoop: "Capture frames and loop segments"
    case .debugConsole: "Diagnostics & statistics"
    }
  }

  var systemImage: String {
    switch self {
    case .polishedPlayer: "play.rectangle.fill"
    case .pictureInPicture: "pip"
    case .audioPlayer: "headphones"
    case .playlist: "list.number"
    case .snapshotAndLoop: "camera.viewfinder"
    case .debugConsole: "ladybug"
    }
  }

  var accentColor: Color {
    switch self {
    case .polishedPlayer: .blue
    case .pictureInPicture: .indigo
    case .audioPlayer: .orange
    case .playlist: .green
    case .snapshotAndLoop: .purple
    case .debugConsole: .red
    }
  }

  /// Whether this demo is available on the current platform. tvOS skips
  /// demos that require pointer/keyboard input or background rendering
  /// paths unavailable on the platform.
  var isAvailable: Bool {
    #if os(tvOS)
    switch self {
    case .polishedPlayer, .playlist, .snapshotAndLoop: true
    case .pictureInPicture, .audioPlayer, .debugConsole: false
    }
    #else
    true
    #endif
  }

  static var available: [ShowcaseItem] {
    allCases.filter(\.isAvailable)
  }
}
