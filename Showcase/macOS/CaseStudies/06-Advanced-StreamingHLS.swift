import SwiftUI
import SwiftVLC

struct MacStreamingHLSCase: View {
  @State private var player = Player()

  var body: some View {
    MacShowcaseContent(
      title: "HLS Streaming",
      summary: "Play an adaptive HTTP Live Streaming URL and inspect live buffering and media statistics.",
      usage: "Play the live stream and watch buffer fill, input bitrate, and decoded video counters update."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Stream") {
          Text(MacTestMedia.hls.absoluteString)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    } sidebar: {
      MacSection(title: "Playback") {
        MacMetricGrid {
          MacMetricRow(title: "State", value: player.state.description)
          MacMetricRow(title: "Buffer", value: "\(Int(player.bufferFill * 100))%")
          MacMetricRow(title: "Read", value: byteLabel(player.statistics?.readBytes))
          MacMetricRow(title: "Input", value: bitrateLabel(player.statistics?.inputBitrate))
          MacMetricRow(title: "Decoded Video", value: "\(player.statistics?.decodedVideo ?? 0)")
        }
      }
      MacLibrarySurface(symbols: ["player.play(url:)", "player.statistics", "player.bufferFill"])
    }
    .task { try? player.play(url: MacTestMedia.hls) }
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
