import SwiftUI
import SwiftVLC

private let readMe = """
`volume` is `0.0...1.25` (values above 1.0 amplify) and `isMuted` is orthogonal — \
muting preserves the underlying level so unmuting restores it.
"""

struct VolumeCase: View {
  @State private var player = Player()

  var body: some View {
    @Bindable var bindable = player

    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Volume") {
        Toggle("Muted", isOn: $bindable.isMuted)
        CompatSlider(value: $bindable.volume, range: 0...1.25, step: 0.05)
        LabeledContent("Level", value: String(format: "%.0f%%", bindable.volume * 100))
      }
    }
    .navigationTitle("Volume")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }
}
