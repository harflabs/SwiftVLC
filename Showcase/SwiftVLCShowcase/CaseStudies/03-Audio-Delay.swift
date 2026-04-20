import SwiftUI
import SwiftVLC

private let readMe = """
`audioDelay` shifts audio timing. Positive values delay audio, negative values advance \
it. Use to fix out-of-sync audio on live streams or misauthored media.
"""

struct AudioDelayCase: View {
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
        CompatSlider(value: $delayMs, range: -2000...2000, step: 10)
        LabeledContent("Offset", value: String(format: "%+d ms", Int(delayMs)))
      }
    }
    .navigationTitle("Audio delay")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onChange(of: delayMs) {
      player.audioDelay = .milliseconds(Int(delayMs))
    }
    .onDisappear { player.stop() }
  }
}
