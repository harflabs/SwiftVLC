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
          .accessibilityIdentifier(AccessibilityID.FrameStep.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.FrameStep.playPauseButton)
      }

      Section("Position") {
        SeekBar(player: player)
      }

      Section("Step") {
        infoRow(
          "Pausable",
          value: player.isPausable ? "yes" : "no",
          identifier: AccessibilityID.FrameStep.pausableLabel
        )
        infoRow(
          "Time",
          value: formatPrecise(player.currentTime),
          identifier: AccessibilityID.FrameStep.timeLabel
        )

        Button("Next frame", systemImage: "forward.frame.fill") {
          player.nextFrame()
        }
        .accessibilityIdentifier(AccessibilityID.FrameStep.nextFrameButton)
        .frame(maxWidth: .infinity)
        .disabled(!player.isPausable || player.isPlaying)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Frame step")
    .task { try? player.play(url: TestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private func infoRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(identifier)
    }
  }

  private func formatPrecise(_ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1e18
    return String(format: "%.3fs", seconds)
  }
}
