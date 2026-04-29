import SwiftUI
import SwiftVLC

struct TVRateCase: View {
  @State private var player = Player()

  private let presets: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]

  var body: some View {
    @Bindable var bindable = player

    TVShowcaseContent(
      title: "Playback Rate",
      summary: "Bind Player.rate to native controls for live speed changes.",
      usage: "Adjust the focused rate slider or pick a preset while media plays to see Player.rate update immediately."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Rate") {
          TVSlider(
            "Rate",
            value: $bindable.rate,
            in: 0.25...2.0,
            step: 0.05
          ) { String(format: "%.2fx", $0) }
          TVControlGrid {
            ForEach(presets, id: \.self) { preset in
              Button(String(format: "%.2fx", preset)) { player.rate = preset }
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Current", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Rate", value: String(format: "%.2fx", player.rate))
          TVMetricRow(title: "State", value: player.state.description)
        }
      }
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
