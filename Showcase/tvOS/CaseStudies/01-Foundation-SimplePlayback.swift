import SwiftUI
import SwiftVLC

struct TVSimplePlaybackCase: View {
  @State private var player = Player()

  var body: some View {
    TVShowcaseContent(
      title: "Simple Playback",
      summary: "Attach a Player to VideoView, start playback from a URL, and let observable state drive the controls.",
      usage: "Use Play/Pause and the scrubber to test a single Player attached to VideoView while the state panel mirrors observable playback values."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
      }
    } sidebar: {
      TVSection(title: "State", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "State", value: player.state.description)
          TVMetricRow(title: "Time", value: durationLabel(player.currentTime))
          TVMetricRow(title: "Duration", value: durationLabel(player.duration))
          TVMetricRow(title: "Seekable", value: player.isSeekable ? "Yes" : "No")
        }
      }
      TVLibrarySurface(symbols: ["Player", "VideoView", "togglePlayPause()"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
