import SwiftUI
import SwiftVLC

struct MacABLoopCase: View {
  @State private var player = Player()
  @State private var aTime: Duration?
  @State private var bTime: Duration?

  var body: some View {
    MacShowcaseContent(
      title: "A-B Loop",
      summary: "Mark two playback times and ask libVLC to loop between them.",
      usage: "Play the media, mark A and B at different times, then clear or replace the loop points to test bounded replay."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Loop Points") {
          HStack {
            Button("Mark A", systemImage: "a.circle") { markAButtonTapped() }
            Button("Mark B", systemImage: "b.circle") { markBButtonTapped() }
              .disabled(aTime == nil)
            Button("Reset", systemImage: "xmark.circle") { resetButtonTapped() }
          }
        }
      }
    } sidebar: {
      MacSection(title: "Loop") {
        MacMetricGrid {
          MacMetricRow(title: "State", value: stateLabel)
          MacMetricRow(title: "A", value: durationLabel(aTime))
          MacMetricRow(title: "B", value: durationLabel(bTime))
          MacMetricRow(title: "Now", value: durationLabel(player.currentTime))
        }
      }
      MacLibrarySurface(symbols: ["player.setABLoop(a:b:)", "player.abLoopState", "player.resetABLoop()"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private var stateLabel: String {
    switch player.abLoopState {
    case .none: "Off"
    case .pointASet: "A Set"
    case .active: "Active"
    }
  }

  private func markAButtonTapped() {
    aTime = player.currentTime
  }

  private func markBButtonTapped() {
    guard let aTime else { return }
    let bTime = player.currentTime
    try? player.setABLoop(a: aTime, b: bTime)
    self.bTime = bTime
  }

  private func resetButtonTapped() {
    aTime = nil
    bTime = nil
    try? player.resetABLoop()
  }
}
