import SwiftUI
import SwiftVLC

struct TVDeinterlacingCase: View {
  @State private var player = Player()
  @State private var state: Deinterlace = .auto
  @State private var mode: Mode = .yadif

  var body: some View {
    TVShowcaseContent(
      title: "Deinterlacing",
      summary: "Toggle libVLC deinterlacing state and mode for interlaced broadcast or disc sources.",
      usage: "Toggle deinterlacing and select a mode to see the current libVLC video filter configuration."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Filter") {
          VStack(alignment: .leading, spacing: 12) {
            Text("State")
              .font(.headline)

            TVChoiceGrid {
              ForEach(Deinterlace.allCases) { state in
                TVChoiceButton(
                  title: state.label,
                  isSelected: self.state == state
                ) {
                  stateButtonTapped(state)
                }
              }
            }
          }

          VStack(alignment: .leading, spacing: 12) {
            Text("Mode")
              .font(.headline)

            TVChoiceGrid {
              ForEach(Mode.allCases) { mode in
                TVChoiceButton(
                  title: mode.rawValue.capitalized,
                  isSelected: self.mode == mode
                ) {
                  modeButtonTapped(mode)
                }
              }
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Current", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "State", value: state.label)
          TVMetricRow(title: "Mode", value: mode.rawValue)
        }
      }
      TVLibrarySurface(symbols: ["player.setDeinterlace(state:mode:)"])
    }
    .task { task() }
    .onDisappear { player.stop() }
  }

  private func task() {
    try? player.play(url: TVTestMedia.demo)
    applyDeinterlace()
  }

  private func stateButtonTapped(_ state: Deinterlace) {
    self.state = state
    applyDeinterlace()
  }

  private func modeButtonTapped(_ mode: Mode) {
    self.mode = mode
    applyDeinterlace()
  }

  private func applyDeinterlace() {
    try? player.setDeinterlace(state: state.rawValue, mode: mode.rawValue)
  }
}

private enum Deinterlace: Int, CaseIterable, Identifiable {
  case off = 0
  case on = 1
  case auto = -1

  var id: Int {
    rawValue
  }

  var label: String {
    switch self {
    case .off: "Off"
    case .on: "On"
    case .auto: "Auto"
    }
  }
}

private enum Mode: String, CaseIterable, Identifiable {
  case blend, bob, yadif, x, mean, linear

  var id: String {
    rawValue
  }
}
