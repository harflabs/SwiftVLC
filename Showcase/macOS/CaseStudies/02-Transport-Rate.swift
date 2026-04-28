import SwiftUI
import SwiftVLC

struct MacRateCase: View {
  @State private var player = Player()

  private let presets: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]

  var body: some View {
    @Bindable var bindable = player

    MacShowcaseContent(
      title: "Playback Rate",
      summary: "Bind Player.rate to native controls for live speed changes.",
      usage: "Move the rate slider or pick a preset while media plays to see Player.rate update immediately."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Rate") {
          Slider(value: $bindable.rate, in: 0.25...2.0)
          HStack {
            ForEach(presets, id: \.self) { preset in
              Button(String(format: "%.2fx", preset)) { player.rate = preset }
            }
          }
        }
      }
    } sidebar: {
      MacSection(title: "Current") {
        MacMetricGrid {
          MacMetricRow(title: "Rate", value: String(format: "%.2fx", player.rate))
          MacMetricRow(title: "State", value: player.state.description)
        }
      }
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
