import SwiftUI
import SwiftVLC

struct MusicPlayerApp: View {
  @State private var presented: Song?

  private var library: [Song] {
    if LaunchArguments.isUITestMode, LaunchArguments.musicFixtureURLValues.count >= 3 {
      return zip(Self.defaultLibrary, LaunchArguments.musicFixtureURLValues).map { song, url in
        Song(id: song.id, title: song.title, artist: song.artist, url: url)
      }
    }
    return Self.defaultLibrary
  }

  private static let defaultLibrary: [Song] = [
    Song(id: "showcase-reel", title: "Showcase Reel", artist: "SwiftVLC", url: TestMedia.demo),
    Song(id: "big-buck-bunny", title: "Big Buck Bunny", artist: "Blender Foundation", url: TestMedia.bigBuckBunny),
    Song(id: "hls-test-stream", title: "HLS test stream", artist: "Mux", url: TestMedia.hls)
  ]

  var body: some View {
    List(library) { song in
      Button { presented = song } label: {
        SongRow(song: song)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(AccessibilityID.MusicPlayer.songButton(song.title))
    }
    .navigationTitle("Music Player")
    .fullScreenCover(item: $presented) { song in
      NowPlayingView(song: song)
    }
  }
}

struct Song: Identifiable, Hashable {
  let id: String
  let title: String
  let artist: String
  let url: URL
}

private struct SongRow: View {
  let song: Song

  var body: some View {
    HStack(spacing: 16) {
      RoundedRectangle(cornerRadius: 8)
        .fill(
          LinearGradient(
            colors: [.blue.opacity(0.8), .purple.opacity(0.8)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: 48, height: 48)
        .overlay {
          Image(systemName: "music.note").foregroundStyle(.white)
        }

      VStack(alignment: .leading) {
        Text(song.title).font(.headline)
        Text(song.artist).font(.caption).foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}
