import SwiftUI
import SwiftVLC

private let readMe = """
`seek(by:)` jumps forward or backward by a `Duration` offset — no absolute time math \
required.
"""

struct RelativeSeekCase: View {
  @State private var player = Player()

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.RelativeSeek.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.RelativeSeek.playPauseButton)
      }

      Section("Position") {
        SeekBar(player: player)
      }

      Section("Skip") {
        HStack(spacing: 12) {
          skip(-30, identifier: AccessibilityID.RelativeSeek.skipBack30)
          skip(-10, identifier: AccessibilityID.RelativeSeek.skipBack10)
          skip(+10, identifier: AccessibilityID.RelativeSeek.skipForward10)
          skip(+30, identifier: AccessibilityID.RelativeSeek.skipForward30)
        }
        // Each skip Button needs an explicit hit target, otherwise the
        // Form row swallows individual taps and routes them through the
        // cell. See `ABLoopCase` for the same fix.
        .buttonStyle(.borderless)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Relative seek")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }

  private func skip(_ seconds: Int, identifier: String) -> some View {
    Button {
      player.seek(by: .seconds(seconds))
    } label: {
      Text(seconds > 0 ? "+\(seconds)s" : "\(seconds)s")
        .frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier(identifier)
  }
}
