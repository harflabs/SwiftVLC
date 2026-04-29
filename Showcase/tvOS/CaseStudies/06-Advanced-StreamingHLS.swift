import SwiftUI
import SwiftVLC

struct TVStreamingHLSCase: View {
  @State private var player = Player()

  var body: some View {
    TVShowcaseContent(
      title: "HLS Streaming",
      summary: "Play an adaptive HTTP Live Streaming URL and inspect live buffering and media statistics.",
      usage: "Play the live stream and watch buffer fill, input bitrate, and decoded video counters update."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
        TVSection(title: "Stream", isFocusable: true) {
          Text(TVTestMedia.hls.absoluteString)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } sidebar: {
      TVSection(title: "Playback", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "State", value: player.state.description)
          TVMetricRow(title: "Buffer", value: "\(Int(player.bufferFill * 100))%")
          TVMetricRow(title: "Read", value: byteLabel(player.statistics?.readBytes))
          TVMetricRow(title: "Input", value: bitrateLabel(player.statistics?.inputBitrate))
          TVMetricRow(title: "Decoded Video", value: "\(player.statistics?.decodedVideo ?? 0)")
        }
      }
      TVLibrarySurface(symbols: ["player.play(url:)", "player.statistics", "player.bufferFill"])
    }
    .task { try? player.play(url: TVTestMedia.hls) }
    .onDisappear { player.stop() }
  }

  private func byteLabel(_ bytes: UInt64?) -> String {
    guard let bytes else { return "--" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private func bitrateLabel(_ bitrate: Float?) -> String {
    guard let bitrate else { return "--" }
    return String(format: "%.2f Mbps", bitrate * 8)
  }
}
