import SwiftUI
import SwiftVLC

private let readMe = """
`player.marquee` renders text over video. Set text via `setText(_:)`, adjust opacity \
and position via properties. Marquee is a non-copyable borrowed view — mutations \
must go through `player.withMarquee { ... }` or direct statements.
"""

struct MarqueeCase: View {
  @State private var player = Player()
  @State private var isEnabled = false
  @State private var text = "SwiftVLC"
  @State private var opacity: Double = 255

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

      Section("Marquee") {
        Toggle("Enabled", isOn: $isEnabled)
        TextField("Text", text: $text)
        VStack(alignment: .leading) {
          LabeledContent("Opacity", value: String(format: "%.0f%%", opacity / 255 * 100))
          CompatSlider(value: $opacity, range: 0...255, step: 5)
        }
      }
    }
    .navigationTitle("Marquee")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onChange(of: isEnabled) { player.withMarquee { $0.isEnabled = isEnabled } }
    .onChange(of: text) { player.withMarquee { $0.setText(text) } }
    .onChange(of: opacity) { player.withMarquee { $0.opacity = Int(opacity) } }
    .onDisappear { player.stop() }
  }
}
