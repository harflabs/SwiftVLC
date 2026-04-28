import SwiftUI
import SwiftVLC

struct MacRelativeSeekCase: View {
  @State private var player = Player()

  private let offsets: [Double] = [-30, -10, -5, 5, 10, 30]

  var body: some View {
    MacShowcaseContent(
      title: "Relative Seek",
      summary: "Jump forward or backward by a Duration without doing manual absolute-time math.",
      usage: "Use the skip buttons to jump backward or forward by fixed durations, then compare current time and seekability in the inspector."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Jumps") {
          HStack {
            ForEach(offsets, id: \.self) { offset in
              Button(label(for: offset)) { player.seek(by: .seconds(offset)) }
            }
          }
          .disabled(!player.isSeekable)
        }
      }
    } sidebar: {
      MacSection(title: "Timing") {
        MacMetricGrid {
          MacMetricRow(title: "Current", value: durationLabel(player.currentTime))
          MacMetricRow(title: "Duration", value: durationLabel(player.duration))
          MacMetricRow(title: "Seekable", value: player.isSeekable ? "Yes" : "No")
        }
      }
      MacLibrarySurface(symbols: ["player.seek(by:)", "Duration.seconds(_:)"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private func label(for offset: Double) -> String {
    offset < 0 ? "\(Int(abs(offset)))s Back" : "\(Int(offset))s Forward"
  }
}
