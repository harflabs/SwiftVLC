import SwiftUI
import SwiftVLC

private let readMe = """
Every playback transition flows through `Player.state`.

SwiftUI re-renders when the enum changes, so the label below reflects each step \
from `idle` through `opening`, `buffering`, `playing`, `paused`, and `stopped`.
"""

struct PlayerStateCase: View {
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

      Section("Live state") {
        LabeledContent("State", value: label)
        LabeledContent("Seekable", value: player.isSeekable ? "yes" : "no")
        LabeledContent("Pausable", value: player.isPausable ? "yes" : "no")
      }
    }
    .navigationTitle("Player state")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }

  private var label: String {
    switch player.state {
    case .idle: "idle"
    case .opening: "opening"
    case .buffering(let p): "buffering \(Int(p * 100))%"
    case .playing: "playing"
    case .paused: "paused"
    case .stopped: "stopped"
    case .stopping: "stopping"
    case .error: "error"
    }
  }
}
