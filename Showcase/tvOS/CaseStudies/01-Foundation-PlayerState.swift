import SwiftUI
import SwiftVLC

struct TVPlayerStateCase: View {
  @State private var player = Player()

  var body: some View {
    TVShowcaseContent(
      title: "Player State",
      summary: "Observe lifecycle, buffer, timing, and media capability values directly from Player.",
      usage: "Start playback, pause, seek, and observe how Player state, timing, buffering, and capability flags change live."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
      }
    } sidebar: {
      TVSection(title: "Playback", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "State", value: player.state.description)
          TVMetricRow(title: "Playing", value: player.isPlaying ? "Yes" : "No")
          TVMetricRow(title: "Active", value: player.isActive ? "Yes" : "No")
          TVMetricRow(title: "Buffer", value: "\(Int(player.bufferFill * 100))%")
          TVMetricRow(title: "Position", value: String(format: "%.3f", player.position))
        }
      }

      TVSection(title: "Media", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Current", value: durationLabel(player.currentTime))
          TVMetricRow(title: "Duration", value: durationLabel(player.duration))
          TVMetricRow(title: "Seekable", value: player.isSeekable ? "Yes" : "No")
          TVMetricRow(title: "Pausable", value: player.isPausable ? "Yes" : "No")
        }
      }
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
