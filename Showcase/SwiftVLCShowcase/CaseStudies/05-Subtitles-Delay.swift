import SwiftUI
import SwiftVLC

private let readMe = """
`subtitleDelay` shifts subtitle timing. Positive values delay subtitles, negative \
values advance them.
"""

struct SubtitlesDelayCase: View {
  @State private var player = Player()
  @State private var delayMs: Double = 0

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Delay") {
        CompatSlider(value: $delayMs, range: -5000...5000, step: 50)
        LabeledContent("Offset", value: String(format: "%+d ms", Int(delayMs)))
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Subtitle delay")
    .task { try? player.play(url: TestMedia.tearsOfSteel) }
    .onChange(of: delayMs) {
      player.subtitleDelay = .milliseconds(Int(delayMs))
    }
    .onDisappear { player.stop() }
  }
}
