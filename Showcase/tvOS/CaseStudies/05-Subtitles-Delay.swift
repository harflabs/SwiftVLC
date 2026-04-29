import SwiftUI
import SwiftVLC

struct TVSubtitlesDelayCase: View {
  @State private var player = Player()
  @State private var delayMs: Double = 0

  var body: some View {
    TVShowcaseContent(
      title: "Subtitle Delay",
      summary: "Shift subtitle timing independently from audio and video.",
      usage: "Step the delay earlier or later and compare the applied offset with available subtitle tracks."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Delay") {
          TVSlider(
            "Offset",
            value: $delayMs,
            in: -2000...2000,
            step: 10
          ) { String(format: "%+d ms", Int($0)) }
          HStack {
            Text("Offset")
            Spacer()
            Text(String(format: "%+d ms", Int(delayMs)))
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
    } sidebar: {
      TVSection(title: "Timing", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Subtitle Delay", value: String(format: "%+d ms", Int(delayMs)))
          TVMetricRow(title: "Subtitles", value: "\(player.subtitleTracks.count)")
        }
      }
      TVLibrarySurface(symbols: ["player.subtitleDelay"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onChange(of: delayMs) { player.subtitleDelay = .milliseconds(Int(delayMs)) }
    .onDisappear { player.stop() }
  }
}
