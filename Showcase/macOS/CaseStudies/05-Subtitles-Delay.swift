import SwiftUI
import SwiftVLC

struct MacSubtitlesDelayCase: View {
  @State private var player = Player()
  @State private var delayMs: Double = 0

  var body: some View {
    MacShowcaseContent(
      title: "Subtitle Delay",
      summary: "Shift subtitle timing independently from audio and video.",
      usage: "Move the delay slider to shift subtitle timing and compare the applied offset with available subtitle tracks."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Delay") {
          Slider(value: $delayMs, in: -2000...2000, step: 10)
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
      MacSection(title: "Timing") {
        MacMetricGrid {
          MacMetricRow(title: "Subtitle Delay", value: String(format: "%+d ms", Int(delayMs)))
          MacMetricRow(title: "Subtitles", value: "\(player.subtitleTracks.count)")
        }
      }
      MacLibrarySurface(symbols: ["player.subtitleDelay"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onChange(of: delayMs) { player.subtitleDelay = .milliseconds(Int(delayMs)) }
    .onDisappear { player.stop() }
  }
}
