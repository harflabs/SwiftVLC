import SwiftUI
import SwiftVLC

struct MacPlaylistQueueCase: View {
  @State private var player = Player()
  @State private var listPlayer = MediaListPlayer()
  @State private var list = MediaList()
  @State private var selectedSourceID: Source.ID? = Source.demo.id
  @State private var playbackMode: PlaybackMode = .default

  private let sources = Source.all
  private let playbackModes: [PlaybackMode] = [.default, .loop, .repeat]

  var body: some View {
    MacShowcaseContent(
      title: "Queue",
      summary: "Wrap a Player in MediaListPlayer to play a queue, loop it, or repeat the current item.",
      usage: "Select queue items, switch repeat mode, and use the list-player transport controls to test MediaListPlayer behavior."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Queue") {
          Picker("Mode", selection: $playbackMode) {
            ForEach(playbackModes, id: \.self) { mode in
              Text(mode.description.capitalized).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .onChange(of: playbackMode) { playbackModeChanged() }

          List(sources, selection: $selectedSourceID) { source in
            Text(source.title).tag(source.id)
          }
          .frame(minHeight: 140)
          .onChange(of: selectedSourceID) { selectedSourceChanged() }

          HStack {
            Button("Previous", systemImage: "backward.fill") { try? listPlayer.previous() }
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
              listPlayer.togglePause()
            }
            Button("Next", systemImage: "forward.fill") { try? listPlayer.next() }
          }
        }
      }
    } sidebar: {
      MacSection(title: "List Player") {
        MacMetricGrid {
          MacMetricRow(title: "Items", value: "\(list.count)")
          MacMetricRow(title: "Mode", value: playbackMode.description)
          MacMetricRow(title: "State", value: listPlayer.state.description)
        }
      }
      MacLibrarySurface(symbols: ["MediaList", "MediaListPlayer", "listPlayer.play(at:)"])
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

  private func selectedSourceChanged() {
    guard let index = sources.firstIndex(where: { $0.id == selectedSourceID }) else { return }
    try? listPlayer.play(at: index)
  }
}

private struct Source: Identifiable, Hashable {
  let id: String
  let title: String
  let url: URL

  static let demo = Source(id: "demo", title: "Demo reel", url: MacTestMedia.demo)
  static let bunny = Source(id: "bunny", title: "Big Buck Bunny", url: MacTestMedia.bigBuckBunny)
  static let hls = Source(id: "hls", title: "HLS stream", url: MacTestMedia.hls)
  static let all = [demo, bunny, hls]
}
