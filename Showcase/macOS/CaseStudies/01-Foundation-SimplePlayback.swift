import SwiftUI
import SwiftVLC

struct MacSimplePlaybackCase: View {
  @State private var player = Player()

  var body: some View {
    MacShowcaseContent(
      title: "Simple Playback",
      summary: "Attach a Player to VideoView, start playback from a URL, and let observable state drive the controls.",
      usage: "Use Play/Pause and the scrubber to test a single Player attached to VideoView while the state panel mirrors observable playback values."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
      }
    } sidebar: {
      MacSection(title: "State") {
        MacMetricGrid {
          MacMetricRow(title: "State", value: player.state.description)
          MacMetricRow(title: "Time", value: durationLabel(player.currentTime))
          MacMetricRow(title: "Duration", value: durationLabel(player.duration))
          MacMetricRow(title: "Seekable", value: player.isSeekable ? "Yes" : "No")
        }
      }
      MacLibrarySurface(symbols: ["Player", "VideoView", "togglePlayPause()"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
