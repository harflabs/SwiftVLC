import SwiftUI
import SwiftVLC

struct MacDeinterlacingCase: View {
  @State private var player = Player()
  @State private var state: Deinterlace = .auto
  @State private var mode: Mode = .yadif

  var body: some View {
    MacShowcaseContent(
      title: "Deinterlacing",
      summary: "Toggle libVLC deinterlacing state and mode for interlaced broadcast or disc sources.",
      usage: "Toggle deinterlacing and select a mode to see the current libVLC video filter configuration."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Filter") {
          Picker("State", selection: $state) {
            ForEach(Deinterlace.allCases) { state in
              Text(state.label).tag(state)
            }
          }
          .pickerStyle(.segmented)
          .onChange(of: state) { applyDeinterlace() }

          Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          .onChange(of: mode) { applyDeinterlace() }
        }
      }
    } sidebar: {
      MacSection(title: "Current") {
        MacMetricGrid {
          MacMetricRow(title: "State", value: state.label)
          MacMetricRow(title: "Mode", value: mode.rawValue)
        }
      }
      MacLibrarySurface(symbols: ["player.setDeinterlace(state:mode:)"])
    }
    .task { task() }
    .onDisappear { player.stop() }
  }

  private func task() {
    try? player.play(url: MacTestMedia.demo)
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
