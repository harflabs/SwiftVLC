import SwiftUI
import SwiftVLC

struct MusicPlayerApp: View {
  @State private var presented: Song?

  private let library: [Song] = [
    Song(title: "Big Buck Bunny", artist: "Blender Foundation", url: TestMedia.bigBuckBunny),
    Song(title: "Tears of Steel", artist: "Blender Foundation", url: TestMedia.tearsOfSteel),
    Song(title: "HLS test stream", artist: "Mux", url: TestMedia.hls)
  ]

  var body: some View {
    List(library) { song in
      Button { presented = song } label: {
        SongRow(song: song)
      }
      .buttonStyle(.plain)
    }
    .navigationTitle("Music Player")
    #if os(macOS)
      .sheet(item: $presented) { song in
        NowPlayingView(song: song)
          .frame(minWidth: 480, minHeight: 720)
      }
    #else
      .fullScreenCover(item: $presented) { song in
        NowPlayingView(song: song)
      }
    #endif
  }
}

struct Song: Identifiable, Hashable {
  var id: URL {
    url
  }

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
