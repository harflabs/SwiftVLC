import SwiftUI
import SwiftVLC

struct MacPiPCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?

  var body: some View {
    MacShowcaseContent(
      title: "Picture in Picture",
      summary: "Use PiPVideoView when the app needs an AVPictureInPictureController-compatible video surface.",
      usage: "Start playback, then use the Picture in Picture control to hand the PiPVideoView surface to AppKit's PiP controller."
    ) {
      VStack(spacing: 16) {
        PiPVideoView(player, controller: $controller)
          .aspectRatio(16 / 9, contentMode: .fit)
          .background(.black, in: .rect(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.secondary.opacity(0.25))
          }
        MacPlaybackControls(player: player)
        MacSection(title: "Picture in Picture") {
          if let controller {
            Button(controller.isActive ? "Stop PiP" : "Start PiP", systemImage: "pip") { controller.toggle() }
              .disabled(!controller.isPossible)
          } else {
            ProgressView("Preparing...")
          }
        }
      }
    } sidebar: {
      MacSection(title: "Controller") {
        MacMetricGrid {
          MacMetricRow(title: "Ready", value: controller == nil ? "No" : "Yes")
          MacMetricRow(title: "Possible", value: controller?.isPossible == true ? "Yes" : "No")
          MacMetricRow(title: "Active", value: controller?.isActive == true ? "Yes" : "No")
        }
      }
      MacLibrarySurface(symbols: ["PiPVideoView", "PiPController.toggle()"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
