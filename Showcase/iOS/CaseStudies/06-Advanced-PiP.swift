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
          .accessibilityIdentifier(AccessibilityID.PiP.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.PiP.playPauseButton)
      }

      Section {
        if let controller {
          infoRow(
            "Possible",
            value: controller.isPossible ? "yes" : "no",
            identifier: AccessibilityID.PiP.possibleLabel
          )
          infoRow(
            "Active",
            value: controller.isActive ? "yes" : "no",
            identifier: AccessibilityID.PiP.activeLabel
          )

          Button(
            controller.isActive ? "Stop PiP" : "Start PiP",
            systemImage: "pip",
            action: controller.toggle
          )
          .accessibilityIdentifier(AccessibilityID.PiP.toggleButton)
          .frame(maxWidth: .infinity)
          .disabled(!controller.isPossible)
        } else {
          Text("Preparing…")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.PiP.preparingLabel)
        }
      } header: {
        Text("Picture in Picture")
      } footer: {
        if let controller, !controller.isPossible {
          Text("PiP isn't available for the current media or platform state.")
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Picture in Picture")
    .task { try? player.play(url: TestMedia.demo) }
    .onDisappear { player.stop() }
  }

  /// `LabeledContent` aggregates its label with the value into a single
  /// accessibility element, preventing XCUITest from querying the value
  /// independently. Plain HStack + Text keeps `XCUIElement.label`
  /// identical to the visible string.
  private func infoRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(identifier)
    }
  }
}
