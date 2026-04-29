import SwiftUI
import SwiftVLC

struct TVVideoPlayerApp: View {
  @State private var player = Player()
  @State private var selectedSourceID: Source.ID? = Source.demo.id

  private let sources = Source.all

  var body: some View {
    TVShowcaseContent(
      title: "Video Player",
      summary: "A tvOS player shell with source selection, transport controls, and track-aware playback.",
      usage: "Pick a source card with the remote, then use the transport controls to play, seek, mute, and verify track metadata."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: true)
        TVSection(title: "Sources") {
          VStack(spacing: 12) {
            ForEach(sources) { source in
              TVChoiceButton(
                title: source.title,
                subtitle: source.subtitle,
                isSelected: selectedSourceID == source.id
              ) {
                selectedSourceID = source.id
              }
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Current Source", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "State", value: player.state.description)
          TVMetricRow(title: "Audio", value: "\(player.audioTracks.count)")
          TVMetricRow(title: "Subtitles", value: "\(player.subtitleTracks.count)")
          TVMetricRow(title: "Duration", value: durationLabel(player.duration))
        }
      }
      TVLibrarySurface(symbols: ["Player", "VideoView", "audioTracks", "subtitleTracks"])
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
    url: TVTestMedia.demo
  )

  static let bigBuckBunny = Source(
    id: "big-buck-bunny",
    title: "Big Buck Bunny",
    subtitle: "Remote MP4 with 5.1 audio",
    url: TVTestMedia.bigBuckBunny
  )

  static let hls = Source(
    id: "hls",
    title: "Live HLS stream",
    subtitle: "Public adaptive-bitrate test stream",
    url: TVTestMedia.hls
  )

  static let all = [demo, bigBuckBunny, hls]
}
