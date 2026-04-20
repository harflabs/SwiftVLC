import SwiftUI
import SwiftVLC

private let readMe = """
`subtitleTextScale` multiplies the subtitle rendering size. Range 0.1×–5.0×, default 1.0×.
"""

struct SubtitlesScaleCase: View {
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

      Section("Scale") {
        CompatSlider(value: $bindable.subtitleTextScale, range: 0.1...5.0, step: 0.1)
        LabeledContent("Scale", value: String(format: "%.1f×", bindable.subtitleTextScale))
      }
    }
    .navigationTitle("Subtitle scale")
    .task { try? player.play(url: TestMedia.tearsOfSteel) }
    .onDisappear { player.stop() }
  }
}
