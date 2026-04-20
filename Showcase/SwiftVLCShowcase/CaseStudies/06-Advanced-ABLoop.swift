import SwiftUI
import SwiftVLC

private let readMe = """
Mark point A, mark point B, and the player loops between them. `abLoopState` tells \
you whether A is set, the loop is active, or it's off.
"""

struct ABLoopCase: View {
  @State private var player = Player()
  @State private var aTime: Duration?
  @State private var bTime: Duration?

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

      Section("Loop") {
        LabeledContent("State", value: stateLabel)
        LabeledContent("A", value: aTime.map(format) ?? "—")
        LabeledContent("B", value: bTime.map(format) ?? "—")

        HStack {
          Button("Mark A") { aTime = player.currentTime }
          Spacer()
          Button("Mark B") { markB() }
            .disabled(aTime == nil)
          Spacer()
          Button("Reset") { reset() }
            .tint(.red)
        }
      }
    }
    .navigationTitle("A-B loop")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }

  private func markB() {
    guard let a = aTime else { return }
    let b = player.currentTime
    try? player.setABLoop(a: a, b: b)
    bTime = b
  }

  private func reset() {
    aTime = nil
    bTime = nil
    try? player.resetABLoop()
  }

  private var stateLabel: String {
    switch player.abLoopState {
    case .none: "off"
    case .pointASet: "A set"
    case .active: "active"
    }
  }

  private func format(_ duration: Duration) -> String {
    let seconds = Int(duration.components.seconds)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
