import SwiftUI
import SwiftVLC

private let readMe = """
`takeSnapshot(to:width:height:)` writes a PNG to disk. Width or height of `0` \
preserves the source dimension.
"""

struct SnapshotCase: View {
  @State private var player = Player()
  @State private var snapshot: PlatformImage?

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Snapshot.videoView)
      } footer: {
        HStack(spacing: 40) {
          Button(
            player.isPlaying ? "Pause" : "Play",
            systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill",
            action: player.togglePlayPause
          )
          .contentTransition(.symbolEffect(.replace))
          .accessibilityIdentifier(AccessibilityID.Snapshot.playPauseButton)

          Button("Take snapshot", systemImage: "camera.fill", action: capture)
            .accessibilityIdentifier(AccessibilityID.Snapshot.takeSnapshotButton)
        }
        .labelStyle(.iconOnly)
        .font(.largeTitle)
        .frame(maxWidth: .infinity, alignment: .center)
      }

      if let snapshot {
        Section("Last snapshot") {
          Image(platformImage: snapshot)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .listRowInsets(EdgeInsets())
            .accessibilityIdentifier(AccessibilityID.Snapshot.snapshotImage)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Snapshot")
    .task { await task() }
    .onDisappear { player.stop() }
  }

  private func task() async {
    try? player.play(url: TestMedia.bigBuckBunny)
    for await event in player.events {
      if case .snapshotTaken(let path) = event {
        snapshot = PlatformImage(contentsOfFile: path)
      }
    }
  }

  private func capture() {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("snapshot-\(UUID().uuidString).png").path
    try? player.takeSnapshot(to: path, width: 0, height: 0)
  }
}
