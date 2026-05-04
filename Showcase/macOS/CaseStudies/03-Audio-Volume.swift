import SwiftUI
import SwiftVLC

struct MacVolumeCase: View {
  @State private var player = Player()

  var body: some View {
    @Bindable var bindable = player

    MacShowcaseContent(
      title: "Volume",
      summary: "Use checked volume updates alongside regular mute bindings.",
      usage: "Adjust volume or mute from SwiftUI controls and verify the Player.volume and Player.isMuted values stay in sync."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Output") {
          HStack {
            Image(systemName: "speaker.fill")
              .foregroundStyle(.secondary)
            Slider(
              value: Binding(
                get: { player.volume },
                set: { try? player.setAudioVolume(Volume($0)) }
              ),
              in: 0...1.25
            )
            Image(systemName: "speaker.wave.3.fill")
              .foregroundStyle(.secondary)
          }
          Toggle("Muted", isOn: $bindable.isMuted)
            .toggleStyle(.checkbox)
        }
      }
    } sidebar: {
      MacSection(title: "Audio") {
        MacMetricGrid {
          MacMetricRow(title: "Volume", value: "\(Int(player.volume * 100))%")
          MacMetricRow(title: "Muted", value: player.isMuted ? "Yes" : "No")
        }
      }
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
