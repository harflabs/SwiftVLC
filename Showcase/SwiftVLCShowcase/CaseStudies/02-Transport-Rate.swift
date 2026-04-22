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
          .accessibilityIdentifier(AccessibilityID.Rate.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Rate.playPauseButton)
      }

      Section("Rate") {
        HStack {
          Text("Current")
          Spacer()
          Text(String(format: "%.2f×", bindable.rate))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.Rate.currentLabel)
        }
        CompatSlider(value: $bindable.rate, range: 0.25...4.0, step: 0.25)
          .accessibilityIdentifier(AccessibilityID.Rate.slider)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Playback rate")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }
}
