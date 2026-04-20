import SwiftUI
import SwiftVLC

private let readMe = """
`rate` is a playback speed multiplier from 0.25× to 4.0×. Pitch is preserved \
automatically, and changes apply live.
"""

struct RateCase: View {
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

      Section("Rate") {
        LabeledContent("Current", value: String(format: "%.2f×", bindable.rate))
        CompatSlider(value: $bindable.rate, range: 0.25...4.0, step: 0.25)
      }
    }
    .navigationTitle("Playback rate")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }
}
