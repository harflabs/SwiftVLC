import SwiftUI
import SwiftVLC

private let readMe = """
The smallest SwiftVLC player.

`Player` is `@Observable`, so reading `isPlaying` makes SwiftUI re-render the button \
when playback state changes. `VideoView(player)` handles platform-native rendering.
"""

struct SimplePlaybackCase: View {
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
    }
    .navigationTitle("Simple playback")
    .task {
      try? player.play(url: TestMedia.bigBuckBunny)
    }
    .onDisappear { player.stop() }
  }
}
