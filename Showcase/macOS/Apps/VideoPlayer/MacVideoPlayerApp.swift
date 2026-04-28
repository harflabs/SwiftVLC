import SwiftUI
import SwiftVLC

struct MacVideoPlayerApp: View {
  @State private var player = Player()
  @State private var selectedSourceID: Source.ID? = Source.demo.id

  private let sources = Source.all

  var body: some View {
    MacShowcaseContent(
      title: "Video Player",
      summary: "A compact macOS player shell with source selection, transport controls, and track-aware playback.",
      usage: "Select a source from the sidebar list, then use the transport controls to play, seek, mute, and verify track metadata in the inspector."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Sources") {
          List(sources, selection: $selectedSourceID) { source in
            VStack(alignment: .leading, spacing: 2) {
              Text(source.title)
              Text(source.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tag(source.id)
          }
          .frame(minHeight: 150)
        }
      }
    } sidebar: {
      MacSection(title: "Current Source") {
        MacMetricGrid {
          MacMetricRow(title: "State", value: player.state.description)
          MacMetricRow(title: "Audio", value: "\(player.audioTracks.count)")
          MacMetricRow(title: "Subtitles", value: "\(player.subtitleTracks.count)")
          MacMetricRow(title: "Duration", value: durationLabel(player.duration))
        }
      }
      MacLibrarySurface(symbols: ["Player", "VideoView", "audioTracks", "subtitleTracks"])
    }
    .task(id: selectedSourceID) { playSelectedSource() }
    .onDisappear { player.stop() }
  }

  private func playSelectedSource() {
    guard let source = sources.first(where: { $0.id == selectedSourceID }) else { return }
    try? player.play(url: source.url)
  }
}

private struct Source: Identifiable, Hashable {
  let id: String
  let title: String
  let subtitle: String
  let url: URL

  static let demo = Source(
    id: "demo",
    title: "Demo reel",
    subtitle: "Bundled file with tracks, chapters, subtitles, and metadata",
    url: MacTestMedia.demo
  )

  static let bigBuckBunny = Source(
    id: "big-buck-bunny",
    title: "Big Buck Bunny",
    subtitle: "Remote MP4 with 5.1 audio",
    url: MacTestMedia.bigBuckBunny
  )

  static let hls = Source(
    id: "hls",
    title: "Live HLS stream",
    subtitle: "Public adaptive-bitrate test stream",
    url: MacTestMedia.hls
  )

  static let all = [demo, bigBuckBunny, hls]
}
