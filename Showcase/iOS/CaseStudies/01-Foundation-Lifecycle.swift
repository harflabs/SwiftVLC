import SwiftUI
import SwiftVLC

private let readMe = """
Attach the player in `.task`, release it in `.onDisappear`. Swap media by updating \
`.task(id:)`; SwiftUI cancels the old task and runs a fresh one.
"""

struct LifecycleCase: View {
  @State private var player = Player()
  @State private var source = TestMedia.demo

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Lifecycle.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Lifecycle.playPauseButton)
      }

      Section("Source") {
        Picker("Media", selection: $source) {
          Text("Demo reel").tag(TestMedia.demo)
          Text("Big Buck Bunny").tag(TestMedia.bigBuckBunny)
          Text("HLS stream").tag(TestMedia.hls)
        }
        .accessibilityIdentifier(AccessibilityID.Lifecycle.sourcePicker)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Lifecycle")
    .task(id: source) { try? player.play(url: source) }
    .onDisappear { player.stop() }
  }
}
