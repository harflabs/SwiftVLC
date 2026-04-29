import SwiftUI
import SwiftVLC

struct TVMetadataCase: View {
  @State private var metadata: Metadata?
  @State private var isParsing = false

  var body: some View {
    TVShowcaseContent(
      title: "Metadata",
      summary: "Create Media from a URL, parse it asynchronously, and read typed metadata fields.",
      usage: "Parse the sample media and inspect typed metadata such as title, artist, album, language, and duration."
    ) {
      TVSection(title: "Parsed Fields", isFocusable: true) {
        if isParsing {
          ProgressView()
        } else {
          TVMetricGrid {
            TVMetricRow(title: "Title", value: metadata?.title ?? "--")
            TVMetricRow(title: "Artist", value: metadata?.artist ?? "--")
            TVMetricRow(title: "Album", value: metadata?.album ?? "--")
            TVMetricRow(title: "Genre", value: metadata?.genre ?? "--")
            TVMetricRow(title: "Date", value: metadata?.date ?? "--")
            TVMetricRow(title: "Duration", value: durationLabel(metadata?.duration))
            TVMetricRow(title: "Language", value: metadata?.language ?? "--")
          }
        }
      }
    } sidebar: {
      TVSection(title: "Source", isFocusable: true) {
        Text(TVTestMedia.demo.lastPathComponent)
      }
      TVLibrarySurface(symbols: ["Media(url:)", "media.parse()", "Metadata"])
    }
    .task { await task() }
  }

  private func task() async {
    isParsing = true
    defer { isParsing = false }
    if let media = try? Media(url: TVTestMedia.demo) {
      metadata = try? await media.parse()
    }
  }
}
