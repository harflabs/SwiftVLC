import SwiftUI
import SwiftVLC
import UniformTypeIdentifiers

private let readMe = """
Load a local `.srt`, `.vtt`, or `.ass` file via `addExternalTrack(from:type:select:)`. \
Passing `select: true` activates the new track immediately.
"""

struct SubtitlesExternalCase: View {
  @State private var player = Player()
  @State private var isPickingFile = false
  @State private var loaded: URL?

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

      Section("Position") {
        SeekBar(player: player)
      }

      Section {
        Button("Load subtitle file…", systemImage: "doc.badge.plus") {
          isPickingFile = true
        }
        .frame(maxWidth: .infinity)

        if let loaded {
          LabeledContent("Loaded", value: loaded.lastPathComponent)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("External subtitles")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
    #if os(iOS) || os(macOS)
      .fileImporter(
        isPresented: $isPickingFile,
        allowedContentTypes: [.plainText, .data]
      ) { result in
        if case .success(let url) = result {
          try? player.addExternalTrack(from: url, type: .subtitle, select: true)
          loaded = url
        }
      }
    #endif
  }
}
