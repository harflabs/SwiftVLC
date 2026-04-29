import SwiftUI
import SwiftVLC

struct TVVolumeCase: View {
  @State private var player = Player()

  var body: some View {
    @Bindable var bindable = player

    TVShowcaseContent(
      title: "Volume",
      summary: "Use Player.volume and Player.isMuted as regular SwiftUI bindings.",
      usage: "Adjust volume or mute from SwiftUI controls and verify the Player.volume and Player.isMuted values stay in sync."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Output") {
          HStack {
            Image(systemName: "speaker.fill")
              .foregroundStyle(.secondary)
            TVSlider(
              "Volume",
              value: $bindable.volume,
              in: 0...1.25,
              step: 0.05
            ) { "\(Int($0 * 100))%" }
            Image(systemName: "speaker.wave.3.fill")
              .foregroundStyle(.secondary)
          }
          Toggle("Muted", isOn: $bindable.isMuted)
        }
      }
    } sidebar: {
      TVSection(title: "Audio", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Volume", value: "\(Int(player.volume * 100))%")
          TVMetricRow(title: "Muted", value: player.isMuted ? "Yes" : "No")
        }
      }
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
