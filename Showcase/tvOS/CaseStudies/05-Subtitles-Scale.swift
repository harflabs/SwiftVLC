import SwiftUI
import SwiftVLC

struct TVSubtitlesScaleCase: View {
  @State private var player = Player()

  var body: some View {
    TVShowcaseContent(
      title: "Subtitle Scale",
      summary: "Adjust libVLC's rendered subtitle text scale through the typed method.",
      usage: "Step the scale up or down to resize rendered subtitle text while playback continues."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Scale") {
          TVSlider(
            "Scale",
            value: Binding(
              get: { player.subtitleTextScale },
              set: { player.setSubtitleScale(SubtitleScale($0)) }
            ),
            in: 0.1...5.0,
            step: 0.1
          ) { String(format: "%.1fx", $0) }
          Text(String(format: "%.1fx", player.subtitleTextScale))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    } sidebar: {
      TVSection(title: "Current", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Scale", value: String(format: "%.1fx", player.subtitleTextScale))
          TVMetricRow(title: "Subtitles", value: "\(player.subtitleTracks.count)")
        }
      }
      TVLibrarySurface(symbols: ["player.setSubtitleScale(_:)"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
