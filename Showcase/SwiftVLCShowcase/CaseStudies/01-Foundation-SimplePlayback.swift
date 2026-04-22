import SwiftUI
import SwiftVLC

private let readMe = """
The smallest SwiftVLC player.

`Player` is `@Observable`, so reading `isPlaying` makes SwiftUI re-render the button \
when playback state changes. `VideoView(player)` handles platform-native rendering.
"""

struct SimplePlaybackCase: View {
  @State private var player = Player()

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.SimplePlayback.videoView)
      } footer: {
        VStack(spacing: 12) {
          HStack {
            Text(Self.format(player.currentTime))
              .monospacedDigit()
              .accessibilityIdentifier(AccessibilityID.SimplePlayback.currentTime)
            Spacer()
            Text(player.duration.map(Self.format) ?? "—")
              .monospacedDigit()
              .accessibilityIdentifier(AccessibilityID.SimplePlayback.duration)
          }
          .font(.caption)
          .foregroundStyle(.secondary)

          PlayPauseFooter(player: player)
            .accessibilityIdentifier(AccessibilityID.SimplePlayback.playPauseButton)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Simple playback")
    .task {
      try? player.play(url: TestMedia.bigBuckBunny)
    }
    .onDisappear { player.stop() }
  }

  private static func format(_ duration: Duration) -> String {
    let seconds = Int(duration.components.seconds)
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}
