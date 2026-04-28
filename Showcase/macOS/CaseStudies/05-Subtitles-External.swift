import SwiftUI
import SwiftVLC
import UniformTypeIdentifiers

struct MacSubtitlesExternalCase: View {
  @State private var player = Player()
  @State private var isPickingFile = false
  @State private var loadedURL: URL?

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

  private func fileImporterCompleted(_ result: Result<[URL], any Error>) {
    guard let url = try? result.get().first else { return }
    let isAccessible = url.startAccessingSecurityScopedResource()
    defer {
      if isAccessible {
        url.stopAccessingSecurityScopedResource()
      }
    }
    try? player.addExternalTrack(from: url, type: .subtitle, select: true)
    loadedURL = url
  }
}
