import AppKit
import SwiftUI
import SwiftVLC

struct MacSnapshotCase: View {
  @State private var player = Player()
  @State private var snapshot: NSImage?
  @State private var snapshotPath: String?

  var body: some View {
    MacShowcaseContent(
      title: "Snapshot",
      summary: "Capture the current video frame to a PNG file and show it back in the macOS UI.",
      usage: "Play the sample video and press Capture Snapshot to write a PNG, then inspect the last captured file in the sidebar."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacSection(title: "Capture") {
          HStack {
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
              player.togglePlayPause()
            }
            Button("Take Snapshot", systemImage: "camera.fill") { snapshotButtonTapped() }
          }

          if let snapshot {
            Image(nsImage: snapshot)
              .resizable()
              .aspectRatio(contentMode: .fit)
              .frame(maxHeight: 260)
              .clipShape(.rect(cornerRadius: 8))
          }
        }
      }
    } sidebar: {
      MacSection(title: "Last Snapshot") {
        MacMetricGrid {
          MacMetricRow(title: "Path", value: snapshotPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "--")
          MacMetricRow(title: "State", value: player.state.description)
        }
      }
      MacLibrarySurface(symbols: ["player.takeSnapshot(to:)", "PlayerEvent.snapshotTaken"])
    }
    .task { await task() }
    .onDisappear { player.stop() }
  }

  private func task() async {
    try? player.play(url: MacTestMedia.demo)
    for await event in player.events {
      if case .snapshotTaken(let path) = event {
        snapshotPath = path
        snapshot = NSImage(contentsOfFile: path)
      }
    }
  }

  private func snapshotButtonTapped() {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("swiftvlc-snapshot-\(UUID().uuidString).png")
      .path
    try? player.takeSnapshot(to: path)
  }
}
