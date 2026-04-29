import SwiftUI
import SwiftVLC

struct TVPlaylistQueueCase: View {
  @State private var player = Player()
  @State private var listPlayer = MediaListPlayer()
  @State private var list = MediaList()
  @State private var selectedSourceID: Source.ID? = Source.demo.id
  @State private var playbackMode: PlaybackMode = .default

  private let sources = Source.all
  private let playbackModes: [PlaybackMode] = [.default, .loop, .repeat]

  var body: some View {
    TVShowcaseContent(
      title: "Queue",
      summary: "Wrap a Player in MediaListPlayer to play a queue, loop it, or repeat the current item.",
      usage: "Select queue items with focused buttons, switch repeat mode, and use the list-player transport controls to test MediaListPlayer behavior."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
        TVSection(title: "Queue") {
          TVChoiceGrid {
            ForEach(playbackModes, id: \.self) { mode in
              TVChoiceButton(
                title: mode.description.capitalized,
                isSelected: playbackMode == mode
              ) {
                playbackModeButtonTapped(mode)
              }
            }
          }

          VStack(spacing: 12) {
            ForEach(sources) { source in
              TVChoiceButton(title: source.title, isSelected: selectedSourceID == source.id) {
                selectedSourceID = source.id
              }
            }
          }
          .onChange(of: selectedSourceID) { selectedSourceChanged() }

          TVControlGrid {
            Button("Previous", systemImage: "backward.fill") { try? listPlayer.previous() }
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
              listPlayer.togglePause()
            }
            Button("Next", systemImage: "forward.fill") { try? listPlayer.next() }
          }
        }
      }
    } sidebar: {
      TVSection(title: "List Player", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Items", value: "\(list.count)")
          TVMetricRow(title: "Mode", value: playbackMode.description)
          TVMetricRow(title: "State", value: listPlayer.state.description)
        }
      }
      TVLibrarySurface(symbols: ["MediaList", "MediaListPlayer", "listPlayer.play(at:)"])
    }
    .task { task() }
    .onDisappear { listPlayer.stop() }
  }

  private func task() {
    listPlayer.mediaPlayer = player
    listPlayer.mediaList = list
    playbackModeChanged()
    for source in sources {
      if let media = try? Media(url: source.url) {
        try? list.append(media)
      }
    }
    listPlayer.play()
  }

  private func playbackModeChanged() {
    listPlayer.playbackMode = playbackMode
  }

  private func playbackModeButtonTapped(_ mode: PlaybackMode) {
    playbackMode = mode
    playbackModeChanged()
  }

  private func selectedSourceChanged() {
    guard let index = sources.firstIndex(where: { $0.id == selectedSourceID }) else { return }
    try? listPlayer.play(at: index)
  }
}

private struct Source: Identifiable, Hashable {
  let id: String
  let title: String
  let url: URL

  static let demo = Source(id: "demo", title: "Demo reel", url: TVTestMedia.demo)
  static let bunny = Source(id: "bunny", title: "Big Buck Bunny", url: TVTestMedia.bigBuckBunny)
  static let hls = Source(id: "hls", title: "HLS stream", url: TVTestMedia.hls)
  static let all = [demo, bunny, hls]
}
