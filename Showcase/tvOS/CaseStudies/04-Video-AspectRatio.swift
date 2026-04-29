import SwiftUI
import SwiftVLC

struct TVAspectRatioCase: View {
  @State private var player = Player()
  @State private var selected = Option.default.key

  private let options = Option.all

  var body: some View {
    TVShowcaseContent(
      title: "Aspect Ratio",
      summary: "Switch between source-proportional, fill, and fixed-ratio video rendering modes.",
      usage: "Choose a fitting mode or fixed ratio to compare how VideoView lays out the same media."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Ratio") {
          TVChoiceGrid {
            ForEach(options) { option in
              TVChoiceButton(
                title: option.label,
                isSelected: selected == option.key
              ) {
                optionButtonTapped(option)
              }
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Current", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Aspect", value: selected)
          TVMetricRow(title: "Duration", value: durationLabel(player.duration))
        }
      }
      TVLibrarySurface(symbols: ["player.aspectRatio", "AspectRatio.default", "AspectRatio.fill"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private func optionButtonTapped(_ option: Option) {
    selected = option.key
    player.aspectRatio = option.ratio
  }
}

private struct Option: Identifiable {
  let key: String
  let label: String
  let ratio: AspectRatio

  var id: String {
    key
  }

  static let `default` = Option(key: "default", label: "Default", ratio: .default)
  static let all = [
    `default`,
    Option(key: "fill", label: "Fill", ratio: .fill),
    Option(key: "16:9", label: "16:9", ratio: .ratio(16, 9)),
    Option(key: "4:3", label: "4:3", ratio: .ratio(4, 3)),
    Option(key: "1:1", label: "1:1", ratio: .ratio(1, 1)),
    Option(key: "21:9", label: "21:9", ratio: .ratio(21, 9))
  ]
}
