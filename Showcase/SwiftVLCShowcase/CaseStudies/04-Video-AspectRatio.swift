import SwiftUI
import SwiftVLC

private let readMe = """
`aspectRatio` controls how video fills its rendering surface: `.default` honors the \
source, `.fill` crops to cover, `.ratio(w, h)` forces a specific shape.
"""

struct AspectRatioCase: View {
  @State private var player = Player()
  @State private var selected = "default"

  private let options: [(key: String, label: String, ratio: AspectRatio)] = [
    ("default", "Default", .default),
    ("fill", "Fill", .fill),
    ("16:9", "16 : 9", .ratio(16, 9)),
    ("4:3", "4 : 3", .ratio(4, 3)),
    ("1:1", "1 : 1", .ratio(1, 1)),
    ("21:9", "21 : 9", .ratio(21, 9))
  ]

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.AspectRatio.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.AspectRatio.playPauseButton)
      }

      Section("Aspect ratio") {
        Picker("Ratio", selection: $selected) {
          ForEach(options, id: \.key) { option in
            Text(option.label).tag(option.key)
          }
        }
        .accessibilityIdentifier(AccessibilityID.AspectRatio.ratioPicker)
        .onChange(of: selected) { _, new in
          if let option = options.first(where: { $0.key == new }) {
            player.aspectRatio = option.ratio
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Aspect ratio")
    .task { try? player.play(url: TestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
