import SwiftUI
import SwiftVLC

struct MacFrameStepCase: View {
  @State private var player = Player()

  var body: some View {
    MacShowcaseContent(
      title: "Frame Step",
      summary: "Pause video and advance one decoded frame at a time with Player.nextFrame().",
      usage: "Pause the video, click Next Frame, and use the state panel to confirm single-frame advancement without restarting playback."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Frame Control") {
          HStack {
            Button("Pause", systemImage: "pause.fill") { player.pause() }
            Button("Next Frame", systemImage: "forward.frame.fill") { player.nextFrame() }
              .disabled(!player.isPausable)
          }
        }
      }
    } sidebar: {
      MacSection(title: "Frame State") {
        MacMetricGrid {
          MacMetricRow(title: "State", value: player.state.description)
          MacMetricRow(title: "Pausable", value: player.isPausable ? "Yes" : "No")
          MacMetricRow(title: "Current", value: durationLabel(player.currentTime))
        }
      }
      MacLibrarySurface(symbols: ["player.pause()", "player.nextFrame()"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
