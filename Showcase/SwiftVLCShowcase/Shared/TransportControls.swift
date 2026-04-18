import SwiftUI
import SwiftVLC

/// Reusable skip-back / play-pause / skip-forward transport buttons.
struct TransportControls: View {
  let player: Player
  var skipInterval: Duration = .seconds(10)

  var body: some View {
    HStack(spacing: 32) {
      Button {
        player.seek(by: .zero - skipInterval)
      } label: {
        Label("Skip Back", systemImage: "gobackward.10")
      }
      .accessibilityLabel("Skip back \(Int(skipInterval.components.seconds)) seconds")

      Button {
        player.togglePlayPause()
      } label: {
        Label(
          player.isPlaying ? "Pause" : "Play",
          systemImage: player.isPlaying ? "pause.fill" : "play.fill"
        )
        .font(.largeTitle)
        .contentTransition(.symbolEffect(.replace))
      }
      .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
      .accessibilityAddTraits(.startsMediaSession)

      Button {
        player.seek(by: skipInterval)
      } label: {
        Label("Skip Forward", systemImage: "goforward.10")
      }
      .accessibilityLabel("Skip forward \(Int(skipInterval.components.seconds)) seconds")
    }
    .labelStyle(.iconOnly)
    .font(.title)
    .buttonStyle(.plain)
  }
}
