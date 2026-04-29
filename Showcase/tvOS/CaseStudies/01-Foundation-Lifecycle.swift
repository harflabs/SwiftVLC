import SwiftUI
import SwiftVLC

struct TVLifecycleCase: View {
  @State private var player = Player()
  @State private var selectedSource = Source.demo

  var body: some View {
    TVShowcaseContent(
      title: "Lifecycle",
      summary: "Create a player once, load new media into it, and explicitly stop playback when the view closes.",
      usage: "Switch between bundled, remote, and streaming sources to confirm the same Player loads new media and stops cleanly when the view disappears."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
        TVSection(title: "Media Lifecycle") {
          TVChoiceGrid {
            ForEach(Source.all) { source in
              TVChoiceButton(
                title: source.title,
                isSelected: selectedSource == source
              ) {
                selectedSource = source
              }
            }
          }

          TVControlGrid {
            Button("Load", systemImage: "arrow.down.circle") { loadButtonTapped() }
            Button("Play", systemImage: "play.fill") { playButtonTapped() }
            Button("Stop", systemImage: "stop.fill") { player.stop() }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Lifecycle State", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Source", value: selectedSource.title)
          TVMetricRow(title: "State", value: player.state.description)
          TVMetricRow(title: "Current", value: durationLabel(player.currentTime))
          TVMetricRow(title: "Duration", value: durationLabel(player.duration))
        }
      }
      TVLibrarySurface(symbols: ["Player()", "player.load(_:)", "player.play()", "player.stop()"])
    }
    .task { task() }
    .onChange(of: selectedSource) { loadButtonTapped() }
    .onDisappear { player.stop() }
  }

  private func task() {
    loadButtonTapped()
    playButtonTapped()
  }

  private func loadButtonTapped() {
    if let media = try? Media(url: selectedSource.url) {
      player.load(media)
    }
  }

  private func playButtonTapped() {
    try? player.play()
  }
}

private struct Source: Identifiable, Hashable {
  let id: String
  let title: String
  let url: URL

  static let demo = Source(id: "demo", title: "Demo", url: TVTestMedia.demo)
  static let movie = Source(id: "movie", title: "Remote MP4", url: TVTestMedia.bigBuckBunny)
  static let stream = Source(id: "stream", title: "HLS", url: TVTestMedia.hls)
  static let all = [demo, movie, stream]
}
