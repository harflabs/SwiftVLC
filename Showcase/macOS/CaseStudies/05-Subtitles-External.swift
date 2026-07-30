import SwiftUI
import SwiftVLC
import UniformTypeIdentifiers

struct MacSubtitlesExternalCase: View {
  @State private var player = Player()
  @State private var isPickingFile = false
  @State private var loadedURL: URL?
  @State private var failure: String?

  private let subtitleTypes = [UTType(filenameExtension: "srt") ?? .plainText, .plainText, .text]

  var body: some View {
    MacShowcaseContent(
      title: "External File",
      summary: "Add a sidecar subtitle file at runtime and select it immediately.",
      usage: "Add the bundled sidecar subtitle file, then confirm it appears in Player.subtitleTracks and becomes selectable."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "External Subtitles") {
          Button("Load Subtitle File", systemImage: "doc.badge.plus") { isPickingFile = true }
          if let loadedURL {
            Text(loadedURL.lastPathComponent)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          } else if let failure {
            MacPlaceholderRow(text: "Failed: \(failure)")
          } else {
            MacPlaceholderRow(text: "Choose an .srt or text subtitle file.")
          }
        }
      }
    } sidebar: {
      MacSection(title: "Loaded") {
        MacMetricGrid {
          MacMetricRow(title: "File", value: loadedURL?.lastPathComponent ?? "--")
          MacMetricRow(title: "Subtitles", value: "\(player.subtitleTracks.count)")
        }
      }
      MacLibrarySurface(symbols: ["player.addExternalTrack(from:type:select:)"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .fileImporter(
      isPresented: $isPickingFile,
      allowedContentTypes: subtitleTypes,
      allowsMultipleSelection: false
    ) { fileImporterCompleted($0) }
    .onDisappear { player.stop() }
  }

  /// See the iOS case for the full reasoning: `addExternalTrack` only registers
  /// the URI, so libVLC opens the file on the demuxer thread after this
  /// function has returned and the security scope has closed. Copy into the
  /// container while access is held and hand libVLC the local path.
  private func fileImporterCompleted(_ result: Result<[URL], any Error>) {
    guard let url = try? result.get().first else { return }
    let isAccessible = url.startAccessingSecurityScopedResource()
    defer {
      if isAccessible {
        url.stopAccessingSecurityScopedResource()
      }
    }

    do {
      // Per-load directory, for the reason given in the iOS case: a name-based
      // path lets a same-named reload overwrite a file libVLC is still reading.
      let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let local = directory.appending(path: url.lastPathComponent)
      try FileManager.default.copyItem(at: url, to: local)
      try player.addExternalTrack(from: local, type: .subtitle, select: true)
      loadedURL = local
      failure = nil
    } catch {
      loadedURL = nil
      failure = error.localizedDescription
    }
  }
}
