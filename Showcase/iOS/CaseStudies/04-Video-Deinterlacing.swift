import SwiftUI
import SwiftVLC

private let readMe = """
`setDeinterlace(state:mode:)` toggles deinterlacing. State `-1` lets libVLC decide, \
`0` forces off, `1` forces on. Modes trade quality for cost; `yadif` is a good \
default on modern hardware.

Deinterlacing only has a visible effect on _interlaced_ source video. Most modern \
content (including the sample here) is progressive, so the video won't change as you \
toggle modes.
"""

struct DeinterlacingCase: View {
  @State private var player = Player()
  @State private var state: Deinterlace = .auto
  @State private var mode: Mode = .yadif

  enum Deinterlace: Int, CaseIterable, Identifiable {
    case off = 0, on = 1, auto = -1
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

  enum Mode: String, CaseIterable, Identifiable {
    case blend, bob, yadif, x, mean, linear
    var id: String {
      rawValue
    }
  }

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Deinterlacing.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Deinterlacing.playPauseButton)
      }

      Section("State") {
        Picker("State", selection: $state) {
          ForEach(Deinterlace.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(AccessibilityID.Deinterlacing.statePicker)
      }

      Section("Mode") {
        Picker("Mode", selection: $mode) {
          ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .accessibilityIdentifier(AccessibilityID.Deinterlacing.modePicker)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Deinterlacing")
    .task { task() }
    .onChange(of: state) { apply() }
    .onChange(of: mode) { apply() }
    .onDisappear { player.stop() }
  }

  private func task() {
    try? player.play(url: TestMedia.demo)
    // SwiftUI's `onChange(of:)` doesn't fire for initial values, so
    // the picker's default selection would never reach libVLC. Push
    // once on appear so the UI and the filter agree from frame one.
    apply()
  }

  private func apply() {
    try? player.setDeinterlace(state: state.rawValue, mode: mode.rawValue)
  }
}
