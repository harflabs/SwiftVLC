import SwiftUI
import SwiftVLC

struct TVSubtitlesExternalCase: View {
  @State private var player = Player()
  @State private var loadedURL: URL?

  var body: some View {
    TVShowcaseContent(
      title: "External File",
      summary: "Add a sidecar subtitle file at runtime and select it immediately.",
      usage: "Attach the bundled .srt file from the app bundle, then confirm it appears in Player.subtitleTracks and becomes selected."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "External Subtitles") {
          Button("Attach Bundled Sidecar", systemImage: "captions.bubble") { loadButtonTapped() }
          if let loadedURL {
            Text(loadedURL.lastPathComponent)
              .foregroundStyle(.secondary)
          } else {
            TVPlaceholderRow(text: "Load the bundled .srt file without presenting a file picker.")
          }
        }
      }
    } sidebar: {
      TVSection(title: "Loaded", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "File", value: loadedURL?.lastPathComponent ?? "--")
          TVMetricRow(title: "Subtitles", value: "\(player.subtitleTracks.count)")
        }
      }
      TVLibrarySurface(symbols: ["player.addExternalTrack(from:type:select:)"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private func loadButtonTapped() {
    let url = TVTestMedia.sidecarSubtitles
    try? player.addExternalTrack(from: url, type: .subtitle, select: true)
    loadedURL = url
  }
}
