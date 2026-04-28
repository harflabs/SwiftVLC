import SwiftUI
import SwiftVLC

struct MacMusicPlayerApp: View {
  @State private var player = Player()
  @State private var selectedSongID: Song.ID? = Song.demo.id
  @State private var metadata: Metadata?

  private let songs = Song.all

  var body: some View {
    MacShowcaseContent(
      title: "Music Player",
      summary: "A native macOS now-playing surface focused on audio controls, metadata, and library selection.",
      usage: "Choose a library item, use playback and volume controls, and watch the now-playing metadata update from the selected media."
    ) {
      HStack(alignment: .top, spacing: 20) {
        VStack(spacing: 16) {
          artwork
          MacPlaybackControls(player: player)
        }
        .frame(minWidth: 360)

        MacSection(title: "Library") {
          List(songs, selection: $selectedSongID) { song in
            VStack(alignment: .leading, spacing: 2) {
              Text(song.title)
              Text(song.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tag(song.id)
          }
          .frame(minHeight: 260)
        }
      }
    } sidebar: {
      MacSection(title: "Now Playing") {
        MacMetricGrid {
          MacMetricRow(title: "Title", value: metadata?.title ?? currentSong?.title ?? "--")
          MacMetricRow(title: "Artist", value: metadata?.artist ?? currentSong?.artist ?? "--")
          MacMetricRow(title: "State", value: player.state.description)
          MacMetricRow(title: "Time", value: durationLabel(player.currentTime))
        }
      }
      MacLibrarySurface(symbols: ["Media(url:)", "media.parse()", "Player.volume", "Player.isMuted"])
    }
    .task(id: selectedSongID) { await selectedSongChanged() }
    .onDisappear { player.stop() }
  }

  private var currentSong: Song? {
    songs.first { $0.id == selectedSongID }
  }

  private var artwork: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(.quaternary)
      Image(systemName: "waveform.circle.fill")
        .font(.system(size: 96))
        .foregroundStyle(.orange, .secondary)
    }
    .aspectRatio(1, contentMode: .fit)
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(.separator)
    }
  }

  private func selectedSongChanged() async {
    guard let song = currentSong else { return }
    try? player.play(url: song.url)
    metadata = nil
    if let media = try? Media(url: song.url) {
      let parsedMetadata = try? await media.parse()
      guard !Task.isCancelled, selectedSongID == song.id else { return }
      metadata = parsedMetadata
    }
  }
}

private struct Song: Identifiable, Hashable {
  let id: String
  let title: String
  let artist: String
  let url: URL

  static let demo = Song(id: "demo", title: "Demo reel", artist: "Bundled sample", url: MacTestMedia.demo)
  static let bunny = Song(id: "bunny", title: "Big Buck Bunny", artist: "Blender Foundation", url: MacTestMedia.bigBuckBunny)
  static let hls = Song(id: "hls", title: "HLS Stream", artist: "Mux test stream", url: MacTestMedia.hls)

  static let all = [demo, bunny, hls]
}
