import SwiftUI
import SwiftVLC

struct VideoPlayerApp: View {
  @State private var presented: Source?

  private let sources: [Source] = [
    Source(title: "Big Buck Bunny", subtitle: "Open movie · Blender · 2008", url: TestMedia.bigBuckBunny),
    Source(title: "Tears of Steel", subtitle: "MKV · multiple audio & subtitle tracks", url: TestMedia.tearsOfSteel),
    Source(title: "Live HLS stream", subtitle: "Public test stream · Mux", url: TestMedia.hls)
  ]

  var body: some View {
    List(sources) { source in
      Button { presented = source } label: {
        HStack(spacing: 16) {
          Image(systemName: "play.rectangle.fill")
            .font(.largeTitle)
            .foregroundStyle(.tint)
          VStack(alignment: .leading) {
            Text(source.title).font(.headline)
            Text(source.subtitle).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .navigationTitle("Video Player")
    #if os(macOS)
      .sheet(item: $presented) { source in
        VideoPlayerView(url: source.url, title: source.title)
          .frame(minWidth: 800, minHeight: 500)
      }
    #else
      .fullScreenCover(item: $presented) { source in
        VideoPlayerView(url: source.url, title: source.title)
      }
    #endif
  }
}

struct Source: Identifiable, Hashable {
  var id: URL {
    url
  }

  let title: String
  let subtitle: String
  let url: URL
}
