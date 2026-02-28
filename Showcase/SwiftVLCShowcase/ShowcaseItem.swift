import SwiftUI

enum ShowcaseItem: String, CaseIterable, Identifiable {
  case polishedPlayer
  case pictureInPicture
  case audioPlayer
  case playlist
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
    case .debugConsole: "Debug Console"
    }
  }

  var subtitle: String {
    switch self {
    case .polishedPlayer: "Production-quality video player"
    case .pictureInPicture: "PiP without AVPlayer"
    case .audioPlayer: "Music playback with equalizer"
    case .playlist: "Multi-track queue"
    case .debugConsole: "Diagnostics & statistics"
    }
  }

  var systemImage: String {
    switch self {
    case .polishedPlayer: "play.rectangle.fill"
    case .pictureInPicture: "pip"
    case .audioPlayer: "headphones"
    case .playlist: "list.number"
    case .debugConsole: "ladybug"
    }
  }

  var accentColor: Color {
    switch self {
    case .polishedPlayer: .blue
    case .pictureInPicture: .indigo
    case .audioPlayer: .orange
    case .playlist: .green
    case .debugConsole: .red
    }
  }

  var isAvailable: Bool {
    #if os(tvOS)
    switch self {
    case .polishedPlayer, .playlist: true
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
