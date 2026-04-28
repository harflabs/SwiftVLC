import SwiftUI
import SwiftVLC

private let readMe = """
Every playback transition flows through `Player.state`.

SwiftUI re-renders when the enum changes, so the label below reflects each step \
from `idle` through `opening`, `buffering`, `playing`, `paused`, and `stopped`.
"""

struct PlayerStateCase: View {
  @State private var player = Player()

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PlayerState.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.PlayerState.playPauseButton)
      }

      Section("Live state") {
        row(
          "State",
          value: label,
          identifier: AccessibilityID.PlayerState.stateLabel
        )
        row(
          "Seekable",
          value: player.isSeekable ? "yes" : "no",
          identifier: AccessibilityID.PlayerState.seekableLabel
        )
        row(
          "Pausable",
          value: player.isPausable ? "yes" : "no",
          identifier: AccessibilityID.PlayerState.pausableLabel
        )
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Player state")
    .task { try? player.play(url: TestMedia.demo) }
    .onDisappear { player.stop() }
  }

  /// `LabeledContent` joins its label and content into a single accessibility
  /// element (e.g. "State, playing"), which defeats per-value XCUITest
  /// queries. A plain HStack keeps each value's `XCUIElement.label`
  /// identical to its visible string.
  private func row(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(identifier)
    }
  }

  private var label: String {
    switch player.state {
    case .idle: "idle"
    case .opening: "opening"
    case .buffering: "buffering \(Int(player.bufferFill * 100))%"
    case .playing: "playing"
    case .paused: "paused"
    case .stopped: "stopped"
    case .stopping: "stopping"
    case .error: "error"
    }
  }
}
