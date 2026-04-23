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
          .accessibilityIdentifier(AccessibilityID.SubtitlesScale.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.SubtitlesScale.playPauseButton)
      }

      Section("Scale") {
        CompatSlider(value: $bindable.subtitleTextScale, range: 0.1...5.0, step: 0.1)
          .accessibilityIdentifier(AccessibilityID.SubtitlesScale.slider)
        HStack {
          Text("Scale")
          Spacer()
          Text(String(format: "%.1f×", bindable.subtitleTextScale)).foregroundStyle(.secondary)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Subtitle scale")
    .task { try? player.play(url: TestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
