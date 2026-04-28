import SwiftUI
import SwiftVLC

struct MacAudioDelayCase: View {
  @State private var player = Player()
  @State private var delayMs: Double = 0

  var body: some View {
    MacShowcaseContent(
      title: "Audio Delay",
      summary: "Shift audio earlier or later to compensate for streams with sync drift.",
      usage: "Move the delay slider to shift audio earlier or later and watch the applied millisecond offset in the timing panel."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
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
          MacMetricRow(title: "Audio Delay", value: String(format: "%+d ms", Int(delayMs)))
          MacMetricRow(title: "Current", value: durationLabel(player.currentTime))
        }
      }
      MacLibrarySurface(symbols: ["player.audioDelay"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onChange(of: delayMs) { player.audioDelay = .milliseconds(Int(delayMs)) }
    .onDisappear { player.stop() }
  }
}
