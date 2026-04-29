import SwiftUI
import SwiftVLC

struct TVSeekingCase: View {
  @State private var player = Player()

  var body: some View {
    TVShowcaseContent(
      title: "Seeking",
      summary: "Drive absolute and relative seeks with Player.position, seek(to:), and seek(by:).",
      usage: "Use the focused position controls or jump buttons to exercise absolute and relative seeking from SwiftUI."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        skipControls
      }
    } sidebar: {
      TVSection(title: "Position", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Current", value: durationLabel(player.currentTime))
          TVMetricRow(title: "Duration", value: durationLabel(player.duration))
          TVMetricRow(title: "Seekable", value: player.isSeekable ? "Yes" : "No")
        }
      }
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private var skipControls: some View {
    TVSection(title: "Jump") {
      TVControlGrid {
        Button("Back 30", systemImage: "gobackward.30") { player.seek(by: .seconds(-30)) }
        Button("Back 10", systemImage: "gobackward.10") { player.seek(by: .seconds(-10)) }
        Button("Forward 10", systemImage: "goforward.10") { player.seek(by: .seconds(10)) }
        Button("Forward 30", systemImage: "goforward.30") { player.seek(by: .seconds(30)) }
      }
      .disabled(!player.isSeekable)
    }
  }
}
