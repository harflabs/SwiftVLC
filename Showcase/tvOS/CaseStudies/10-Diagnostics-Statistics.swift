import SwiftUI
import SwiftVLC

struct TVStatisticsCase: View {
  @State private var player = Player()

  var body: some View {
    TVShowcaseContent(
      title: "Statistics",
      summary: "Read live input, demux, decoder, and output counters from the current media.",
      usage: "Start playback and watch input, demux, decoder, and output counters refresh from Player.statistics."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
        TVSection(title: "Live Counters", isFocusable: true) {
          if let stats = player.statistics {
            TVMetricGrid {
              TVMetricRow(title: "Input Read", value: byteLabel(stats.readBytes))
              TVMetricRow(title: "Input Bitrate", value: bitrateLabel(stats.inputBitrate))
              TVMetricRow(title: "Demux Read", value: byteLabel(stats.demuxReadBytes))
              TVMetricRow(title: "Demux Bitrate", value: bitrateLabel(stats.demuxBitrate))
              TVMetricRow(title: "Corrupted", value: "\(stats.demuxCorrupted)")
              TVMetricRow(title: "Discontinuity", value: "\(stats.demuxDiscontinuity)")
            }
          } else {
            ProgressView("Waiting for statistics...")
          }
        }
      }
    } sidebar: {
      TVSection(title: "Decoded", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Video", value: "\(player.statistics?.decodedVideo ?? 0)")
          TVMetricRow(title: "Displayed", value: "\(player.statistics?.displayedPictures ?? 0)")
          TVMetricRow(title: "Late", value: "\(player.statistics?.latePictures ?? 0)")
          TVMetricRow(title: "Lost", value: "\(player.statistics?.lostPictures ?? 0)")
          TVMetricRow(title: "Audio", value: "\(player.statistics?.decodedAudio ?? 0)")
          TVMetricRow(title: "Lost Audio", value: "\(player.statistics?.lostAudioBuffers ?? 0)")
          TVMetricRow(title: "Time", value: durationLabel(player.currentTime))
        }
      }
      TVLibrarySurface(symbols: ["player.statistics", "MediaStatistics"])
    }
    .task { try? player.play(url: TVTestMedia.hls) }
    .onDisappear { player.stop() }
  }

  private func byteLabel(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private func bitrateLabel(_ bitrate: Float) -> String {
    String(format: "%.2f", bitrate)
  }
}
