import SwiftUI
import SwiftVLC

struct MacSubtitlesScaleCase: View {
  @State private var player = Player()

  var body: some View {
    MacShowcaseContent(
      title: "Subtitle Scale",
      summary: "Adjust libVLC's rendered subtitle text scale through the typed method.",
      usage: "Change the scale slider to resize rendered subtitle text while playback continues."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Scale") {
          Slider(
            value: Binding(
              get: { player.subtitleTextScale },
              set: { player.setSubtitleScale(SubtitleScale($0)) }
            ),
            in: 0.1...5.0,
            step: 0.1
          )
          Text(String(format: "%.1fx", player.subtitleTextScale))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    } sidebar: {
      MacSection(title: "Current") {
        MacMetricGrid {
          MacMetricRow(title: "Scale", value: String(format: "%.1fx", player.subtitleTextScale))
          MacMetricRow(title: "Subtitles", value: "\(player.subtitleTracks.count)")
        }
      }
      MacLibrarySurface(symbols: ["player.setSubtitleScale(_:)"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
