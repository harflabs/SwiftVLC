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
  @State private var failure: String?

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.SubtitlesExternal.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.SubtitlesExternal.playPauseButton)
      }

      Section("Position") {
        SeekBar(player: player)
      }

      Section {
        Button("Load subtitle file…", systemImage: "doc.badge.plus") {
          isPickingFile = true
        }
        .accessibilityIdentifier(AccessibilityID.SubtitlesExternal.loadButton)
        .frame(maxWidth: .infinity)

        if let loaded {
          HStack {
            Text("Loaded")
            Spacer()
            Text(loaded.lastPathComponent).foregroundStyle(.secondary)
          }
        }

        if let failure {
          HStack {
            Text("Failed")
            Spacer()
            Text(failure).foregroundStyle(.secondary)
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("External subtitles")
    .task { try? player.play(url: TestMedia.demo) }
    .onDisappear { player.stop() }
    .fileImporter(
      isPresented: $isPickingFile,
      allowedContentTypes: [.plainText, .data]
    ) { result in
      fileImporterCompleted(result)
    }
  }

  /// The picker returns a security-scoped URL, and `addExternalTrack` only
  /// registers the URI with libVLC — the demuxer opens the file later, on its
  /// own thread. By then this function has returned and the scope is closed,
  /// so libVLC gets `Operation not permitted` and the track never appears.
  /// Copying into the container while access is held gives libVLC a path it
  /// can read whenever it gets around to it.
  private func fileImporterCompleted(_ result: Result<URL, any Error>) {
    guard case .success(let url) = result else { return }
    let isAccessible = url.startAccessingSecurityScopedResource()
    defer {
      if isAccessible {
        url.stopAccessingSecurityScopedResource()
      }
    }

    do {
      // A fresh directory per load. A name-based path would let a second
      // subtitle with the same filename overwrite the file libVLC is still
      // reading for the track already added, so each track keeps its own
      // immutable backing file for as long as the player holds it.
      let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let local = directory.appending(path: url.lastPathComponent)
      try FileManager.default.copyItem(at: url, to: local)
      try player.addExternalTrack(from: local, type: .subtitle, select: true)
      loaded = local
      failure = nil
    } catch {
      // Surfaced rather than swallowed: the previous `try?` reported every
      // load as successful, so a track that never loaded looked identical to
      // one that did.
      loaded = nil
      failure = error.localizedDescription
    }
  }
}
