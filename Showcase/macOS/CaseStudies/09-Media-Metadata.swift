import SwiftUI
import SwiftVLC

struct MacMetadataCase: View {
  @State private var metadata: Metadata?
  @State private var isParsing = false

  var body: some View {
    MacShowcaseContent(
      title: "Metadata",
      summary: "Create Media from a URL, parse it asynchronously, and read typed metadata fields.",
      usage: "Parse the sample media and inspect typed metadata such as title, artist, album, language, and duration."
    ) {
      MacSection(title: "Parsed Fields") {
        if isParsing {
          ProgressView()
        } else {
          MacMetricGrid {
            MacMetricRow(title: "Title", value: metadata?.title ?? "--")
            MacMetricRow(title: "Artist", value: metadata?.artist ?? "--")
            MacMetricRow(title: "Album", value: metadata?.album ?? "--")
            MacMetricRow(title: "Genre", value: metadata?.genre ?? "--")
            MacMetricRow(title: "Date", value: metadata?.date ?? "--")
            MacMetricRow(title: "Duration", value: durationLabel(metadata?.duration))
            MacMetricRow(title: "Language", value: metadata?.language ?? "--")
          }
        }
      }
    } sidebar: {
      MacSection(title: "Source") {
        Text(MacTestMedia.demo.lastPathComponent)
          .textSelection(.enabled)
      }
      MacLibrarySurface(symbols: ["Media(url:)", "media.parse()", "Metadata"])
    }
    .task { await task() }
  }

  private func task() async {
    isParsing = true
    defer { isParsing = false }
    if let media = try? Media(url: MacTestMedia.demo) {
      metadata = try? await media.parse()
    }
  }
}
