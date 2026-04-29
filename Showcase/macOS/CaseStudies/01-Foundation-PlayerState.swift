import SwiftUI
import SwiftVLC

struct MacPlayerStateCase: View {
  @State private var player = Player()

  var body: some View {
    MacShowcaseContent(
      title: "Player State",
      summary: "Observe lifecycle, buffer, timing, and media capability values directly from Player.",
      usage: "Start playback, pause, seek, and observe how Player state, timing, buffering, and capability flags change live."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
      }
    } sidebar: {
      MacSection(title: "Playback") {
        MacMetricGrid {
          MacMetricRow(title: "State", value: player.state.description)
          MacMetricRow(title: "Playing", value: player.isPlaying ? "Yes" : "No")
          MacMetricRow(title: "Active", value: player.isActive ? "Yes" : "No")
          MacMetricRow(title: "Buffer", value: "\(Int(player.bufferFill * 100))%")
          MacMetricRow(title: "Position", value: String(format: "%.3f", player.position))
        }
      }

      MacSection(title: "Media") {
        MacMetricGrid {
          MacMetricRow(title: "Current", value: durationLabel(player.currentTime))
          MacMetricRow(title: "Duration", value: durationLabel(player.duration))
          MacMetricRow(title: "Seekable", value: player.isSeekable ? "Yes" : "No")
          MacMetricRow(title: "Pausable", value: player.isPausable ? "Yes" : "No")
        }
      }
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
