import SwiftUI
import SwiftVLC

struct MacStatisticsCase: View {
  @State private var player = Player()

  var body: some View {
    MacShowcaseContent(
      title: "Statistics",
      summary: "Read live input, demux, decoder, and output counters from the current media.",
      usage: "Start playback and watch input, demux, decoder, and output counters refresh from Player.statistics."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Live Counters") {
          if let stats = player.statistics {
            MacMetricGrid {
              MacMetricRow(title: "Input Read", value: byteLabel(stats.readBytes))
              MacMetricRow(title: "Input Bitrate", value: bitrateLabel(stats.inputBitrate))
              MacMetricRow(title: "Demux Read", value: byteLabel(stats.demuxReadBytes))
              MacMetricRow(title: "Demux Bitrate", value: bitrateLabel(stats.demuxBitrate))
              MacMetricRow(title: "Corrupted", value: "\(stats.demuxCorrupted)")
              MacMetricRow(title: "Discontinuity", value: "\(stats.demuxDiscontinuity)")
            }
          } else {
            ProgressView("Waiting for statistics...")
          }
        }
      }
    } sidebar: {
      MacSection(title: "Decoded") {
        MacMetricGrid {
          MacMetricRow(title: "Video", value: "\(player.statistics?.decodedVideo ?? 0)")
          MacMetricRow(title: "Displayed", value: "\(player.statistics?.displayedPictures ?? 0)")
          MacMetricRow(title: "Late", value: "\(player.statistics?.latePictures ?? 0)")
          MacMetricRow(title: "Lost", value: "\(player.statistics?.lostPictures ?? 0)")
          MacMetricRow(title: "Audio", value: "\(player.statistics?.decodedAudio ?? 0)")
          MacMetricRow(title: "Lost Audio", value: "\(player.statistics?.lostAudioBuffers ?? 0)")
          MacMetricRow(title: "Time", value: durationLabel(player.currentTime))
        }
      }
      MacLibrarySurface(symbols: ["player.statistics", "MediaStatistics"])
    }
    .task { try? player.play(url: MacTestMedia.hls) }
    .onDisappear { player.stop() }
  }

  private func byteLabel(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private func bitrateLabel(_ bitrate: Float) -> String {
    String(format: "%.2f", bitrate)
  }
}
