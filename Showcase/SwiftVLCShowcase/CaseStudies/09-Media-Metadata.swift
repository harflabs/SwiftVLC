import SwiftUI
import SwiftVLC

private let readMe = """
`media.parse()` is `async throws` and returns `Metadata` — title, artist, album, \
artwork URL, and more. Parsing is independent of playback.
"""

struct MetadataCase: View {
  @State private var player = Player()
  @State private var metadata: Metadata?

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      if let metadata {
        Section("Metadata") {
          field("Title", metadata.title)
          field("Artist", metadata.artist)
          field("Album", metadata.album)
          field("Genre", metadata.genre)
          field("Date", metadata.date)
          field("Duration", metadata.duration.map { "\(Int($0.components.seconds))s" })
        }
      } else {
        Section { ProgressView("Parsing…") }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Metadata")
    .task {
      try? player.play(url: TestMedia.bigBuckBunny)
      if let media = try? Media(url: TestMedia.bigBuckBunny) {
        metadata = try? await media.parse()
      }
    }
    .onDisappear { player.stop() }
  }

  @ViewBuilder
  private func field(_ label: String, _ value: String?) -> some View {
    if let value, !value.isEmpty {
      LabeledContent(label, value: value)
    }
  }
}
