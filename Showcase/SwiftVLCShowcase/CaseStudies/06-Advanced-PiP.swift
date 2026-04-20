#if os(iOS) || os(macOS)
import SwiftUI
import SwiftVLC

private let readMe = """
`PiPVideoView` uses libVLC's pixel-buffer pipeline to feed `AVPictureInPictureController`. \
The controller reports whether PiP is possible and whether it's currently active.
"""

struct PiPCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        PiPVideoView(player, controller: $controller)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section {
        if let controller {
          LabeledContent("Possible", value: controller.isPossible ? "yes" : "no")
          LabeledContent("Active", value: controller.isActive ? "yes" : "no")

          Button(
            controller.isActive ? "Stop PiP" : "Start PiP",
            systemImage: "pip",
            action: controller.toggle
          )
          .frame(maxWidth: .infinity)
          .disabled(!controller.isPossible)
        } else {
          Text("Preparing…").foregroundStyle(.secondary)
        }
      } header: {
        Text("Picture in Picture")
      } footer: {
        if let controller, !controller.isPossible {
          Text("PiP isn't available for the current media or platform state.")
        }
      }
    }
    .navigationTitle("Picture in Picture")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }
}
#endif
