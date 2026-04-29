import SwiftUI
import SwiftVLC

struct TVFrameStepCase: View {
  @State private var player = Player()

  var body: some View {
    TVShowcaseContent(
      title: "Frame Step",
      summary: "Pause video and advance one decoded frame at a time with Player.nextFrame().",
      usage: "Pause the video, click Next Frame, and use the state panel to confirm single-frame advancement without restarting playback."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Frame Control") {
          TVControlGrid {
            Button("Pause", systemImage: "pause.fill") { player.pause() }
            Button("Next Frame", systemImage: "forward.frame.fill") { player.nextFrame() }
              .disabled(!player.isPausable)
          }
        }
      }
    } sidebar: {
      TVSection(title: "Frame State", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "State", value: player.state.description)
          TVMetricRow(title: "Pausable", value: player.isPausable ? "Yes" : "No")
          TVMetricRow(title: "Current", value: durationLabel(player.currentTime))
        }
      }
      TVLibrarySurface(symbols: ["player.pause()", "player.nextFrame()"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
