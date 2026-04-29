import SwiftUI
import SwiftVLC

private let readMe = """
`position` is a `Double` in `0.0...1.0`, bindable directly to a `Slider`. Seeks are \
async. `currentTime` updates continuously, and `duration` becomes non-nil once known.
"""

struct SeekingCase: View {
  @State private var player = Player()

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Seeking.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Seeking.playPauseButton)
      }

      Section("Position") {
        SeekBar(player: player)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Seeking")
    .task { try? player.play(url: TestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
