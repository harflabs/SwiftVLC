import SwiftUI
import SwiftVLC

private let readMe = """
Pause playback, then call `nextFrame()` to advance one video frame. Requires the \
current media to be `isPausable`.
"""

struct FrameStepCase: View {
  @State private var player = Player()

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

      Section("Position") {
        SeekBar(player: player)
      }

      Section("Step") {
        LabeledContent("Pausable", value: player.isPausable ? "yes" : "no")
        LabeledContent("Time", value: formatPrecise(player.currentTime))

        Button("Next frame", systemImage: "forward.frame.fill") {
          player.nextFrame()
        }
        .frame(maxWidth: .infinity)
        .disabled(!player.isPausable || player.isPlaying)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Frame step")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }

  private func formatPrecise(_ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1e18
    return String(format: "%.3fs", seconds)
  }
}
