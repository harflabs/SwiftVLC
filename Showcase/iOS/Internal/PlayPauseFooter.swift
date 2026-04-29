import SwiftUI
import SwiftVLC

/// Standard play/pause control used beneath every case study's `VideoView`.
struct PlayPauseFooter: View {
  let player: Player

  var body: some View {
    Button(
      player.isPlaying ? "Pause" : "Play",
      systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill",
      action: player.togglePlayPause
    )
    .labelStyle(.iconOnly)
    .contentTransition(.symbolEffect(.replace))
    .font(.largeTitle)
    .frame(maxWidth: .infinity, alignment: .center)
  }
}
