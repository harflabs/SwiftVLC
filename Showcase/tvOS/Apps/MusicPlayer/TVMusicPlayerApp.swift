import SwiftUI
import SwiftVLC

struct TVMusicPlayerApp: View {
  @State private var player = Player()
  @State private var selectedSongID: Song.ID? = Song.demo.id
  @State private var metadata: Metadata?

  private let songs = Song.all

  var body: some View {
    TVShowcaseContent(
      title: "Music Player",
      summary: "A native tvOS now-playing surface focused on audio controls, metadata, and library selection.",
      usage: "Choose a library item, use playback and volume controls, and watch the now-playing metadata update from the selected media."
    ) {
      HStack(alignment: .top, spacing: 24) {
        VStack(alignment: .leading, spacing: 16) {
          artwork
            .frame(width: 280, height: 280)
          TVPlaybackControls(player: player, showsVolume: true)
        }
        .frame(width: 500, alignment: .topLeading)

        TVSection(title: "Library") {
          VStack(spacing: 12) {
            ForEach(songs) { song in
              TVChoiceButton(
                title: song.title,
                subtitle: song.artist,
                isSelected: selectedSongID == song.id
              ) {
                selectedSongID = song.id
              }
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Now Playing", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Title", value: metadata?.title ?? currentSong?.title ?? "--")
          TVMetricRow(title: "Artist", value: metadata?.artist ?? currentSong?.artist ?? "--")
          TVMetricRow(title: "State", value: player.state.description)
          TVMetricRow(title: "Time", value: durationLabel(player.currentTime))
        }
      }
      TVLibrarySurface(symbols: ["Media(url:)", "media.parse()", "Player.volume", "Player.isMuted"])
    }
    .task(id: selectedSongID) { await selectedSongChanged() }
    .onDisappear { player.stop() }
  }

  private var currentSong: Song? {
    songs.first { $0.id == selectedSongID }
  }

  private var artwork: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(.regularMaterial)
      Image(systemName: "waveform.circle.fill")
        .font(.system(size: 96))
        .foregroundStyle(.orange, .secondary)
    }
    .aspectRatio(1, contentMode: .fit)
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(.white.opacity(0.16))
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

  static let demo = Song(id: "demo", title: "Demo reel", artist: "Bundled sample", url: TVTestMedia.demo)
  static let bunny = Song(id: "bunny", title: "Big Buck Bunny", artist: "Blender Foundation", url: TVTestMedia.bigBuckBunny)
  static let hls = Song(id: "hls", title: "HLS Stream", artist: "Mux test stream", url: TVTestMedia.hls)

  static let all = [demo, bunny, hls]
}
