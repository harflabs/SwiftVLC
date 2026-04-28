import SwiftUI
import SwiftVLC

struct MacLifecycleCase: View {
  @State private var player = Player()
  @State private var selectedSource = Source.demo

  var body: some View {
    MacShowcaseContent(
      title: "Lifecycle",
      summary: "Create a player once, load new media into it, and explicitly stop playback when the view closes.",
      usage: "Switch between bundled, remote, and streaming sources to confirm the same Player loads new media and stops cleanly when the view disappears."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Media Lifecycle") {
          Picker("Source", selection: $selectedSource) {
            ForEach(Source.all) { source in
              Text(source.title).tag(source)
            }
          }
          .pickerStyle(.segmented)

          HStack {
            Button("Load", systemImage: "arrow.down.circle") { loadButtonTapped() }
            Button("Play", systemImage: "play.fill") { playButtonTapped() }
            Button("Stop", systemImage: "stop.fill") { player.stop() }
          }
        }
      }
    } sidebar: {
      MacSection(title: "Lifecycle State") {
        MacMetricGrid {
          MacMetricRow(title: "Source", value: selectedSource.title)
          MacMetricRow(title: "State", value: player.state.description)
          MacMetricRow(title: "Current", value: durationLabel(player.currentTime))
          MacMetricRow(title: "Duration", value: durationLabel(player.duration))
        }
      }
      MacLibrarySurface(symbols: ["Player()", "player.load(_:)", "player.play()", "player.stop()"])
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

  static let demo = Source(id: "demo", title: "Demo", url: MacTestMedia.demo)
  static let movie = Source(id: "movie", title: "Remote MP4", url: MacTestMedia.bigBuckBunny)
  static let stream = Source(id: "stream", title: "HLS", url: MacTestMedia.hls)
  static let all = [demo, movie, stream]
}
