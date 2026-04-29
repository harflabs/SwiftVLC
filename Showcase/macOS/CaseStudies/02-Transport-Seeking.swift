import SwiftUI
import SwiftVLC

struct MacSeekingCase: View {
  @State private var player = Player()

  var body: some View {
    MacShowcaseContent(
      title: "Seeking",
      summary: "Drive absolute and relative seeks with Player.position, seek(to:), and seek(by:).",
      usage: "Drag the position slider or use the jump buttons to exercise absolute and relative seeking from SwiftUI."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        skipControls
      }
    } sidebar: {
      MacSection(title: "Position") {
        MacMetricGrid {
          MacMetricRow(title: "Current", value: durationLabel(player.currentTime))
          MacMetricRow(title: "Duration", value: durationLabel(player.duration))
          MacMetricRow(title: "Seekable", value: player.isSeekable ? "Yes" : "No")
        }
      }
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private var skipControls: some View {
    HStack {
      Button("Back 30", systemImage: "gobackward.30") { player.seek(by: .seconds(-30)) }
      Button("Back 10", systemImage: "gobackward.10") { player.seek(by: .seconds(-10)) }
      Spacer()
      Button("Forward 10", systemImage: "goforward.10") { player.seek(by: .seconds(10)) }
      Button("Forward 30", systemImage: "goforward.30") { player.seek(by: .seconds(30)) }
    }
    .disabled(!player.isSeekable)
  }
}
