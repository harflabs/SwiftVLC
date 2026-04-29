import SwiftUI
import SwiftVLC

struct TVRelativeSeekCase: View {
  @State private var player = Player()

  private let offsets: [Double] = [-30, -10, -5, 5, 10, 30]

  var body: some View {
    TVShowcaseContent(
      title: "Relative Seek",
      summary: "Jump forward or backward by a Duration without doing manual absolute-time math.",
      usage: "Use the skip buttons to jump backward or forward by fixed durations, then compare current time and seekability in the inspector."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Jumps") {
          TVControlGrid {
            ForEach(offsets, id: \.self) { offset in
              Button(label(for: offset)) { player.seek(by: .seconds(offset)) }
            }
          }
          .disabled(!player.isSeekable)
        }
      }
    } sidebar: {
      TVSection(title: "Timing", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Current", value: durationLabel(player.currentTime))
          TVMetricRow(title: "Duration", value: durationLabel(player.duration))
          TVMetricRow(title: "Seekable", value: player.isSeekable ? "Yes" : "No")
        }
      }
      TVLibrarySurface(symbols: ["player.seek(by:)", "Duration.seconds(_:)"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private func label(for offset: Double) -> String {
    offset < 0 ? "\(Int(abs(offset)))s Back" : "\(Int(offset))s Forward"
  }
}
