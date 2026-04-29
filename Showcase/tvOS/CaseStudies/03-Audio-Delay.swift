import SwiftUI
import SwiftVLC

struct TVAudioDelayCase: View {
  @State private var player = Player()
  @State private var delayMs: Double = 0

  var body: some View {
    TVShowcaseContent(
      title: "Audio Delay",
      summary: "Shift audio earlier or later to compensate for streams with sync drift.",
      usage: "Step the delay earlier or later and watch the applied millisecond offset in the timing panel."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
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
          TVMetricRow(title: "Audio Delay", value: String(format: "%+d ms", Int(delayMs)))
          TVMetricRow(title: "Current", value: durationLabel(player.currentTime))
        }
      }
      TVLibrarySurface(symbols: ["player.audioDelay"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onChange(of: delayMs) { player.audioDelay = .milliseconds(Int(delayMs)) }
    .onDisappear { player.stop() }
  }
}
