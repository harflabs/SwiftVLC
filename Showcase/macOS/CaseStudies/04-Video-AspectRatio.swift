import SwiftUI
import SwiftVLC

struct MacAspectRatioCase: View {
  @State private var player = Player()
  @State private var selected = Option.default.key

  private let options = Option.all

  var body: some View {
    MacShowcaseContent(
      title: "Aspect Ratio",
      summary: "Switch between source-proportional, fill, and fixed-ratio video rendering modes.",
      usage: "Choose a fitting mode or fixed ratio to compare how VideoView lays out the same media."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Ratio") {
          Picker("Ratio", selection: $selected) {
            ForEach(options) { option in
              Text(option.label).tag(option.key)
            }
          }
          .pickerStyle(.segmented)
          .onChange(of: selected) { ratioPickerChanged() }
        }
      }
    } sidebar: {
      MacSection(title: "Current") {
        MacMetricGrid {
          MacMetricRow(title: "Aspect", value: selected)
          MacMetricRow(title: "Duration", value: durationLabel(player.duration))
        }
      }
      MacLibrarySurface(symbols: ["player.aspectRatio", "AspectRatio.default", "AspectRatio.fill"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private func ratioPickerChanged() {
    guard let option = options.first(where: { $0.key == selected }) else { return }
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
