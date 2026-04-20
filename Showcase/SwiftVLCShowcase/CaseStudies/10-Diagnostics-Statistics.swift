import SwiftUI
import SwiftVLC

private let readMe = """
`player.statistics` exposes live input, demux, decoder, and output counters. Useful \
for debugging streaming, frame drops, and codec behavior.
"""

struct StatisticsCase: View {
  @State private var player = Player()

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      if let stats = player.statistics {
        Section("Input") {
          LabeledContent("Read", value: "\(stats.readBytes) bytes")
          LabeledContent("Bitrate", value: String(format: "%.2f", stats.inputBitrate))
        }

        Section("Demux") {
          LabeledContent("Read", value: "\(stats.demuxReadBytes) bytes")
          LabeledContent("Bitrate", value: String(format: "%.2f", stats.demuxBitrate))
          LabeledContent("Corrupted", value: "\(stats.demuxCorrupted)")
          LabeledContent("Discontinuity", value: "\(stats.demuxDiscontinuity)")
        }

        Section("Video") {
          LabeledContent("Decoded", value: "\(stats.decodedVideo)")
          LabeledContent("Displayed", value: "\(stats.displayedPictures)")
          LabeledContent("Late", value: "\(stats.latePictures)")
            .foregroundStyle(stats.latePictures > 0 ? .orange : .primary)
          LabeledContent("Lost", value: "\(stats.lostPictures)")
            .foregroundStyle(stats.lostPictures > 0 ? .red : .primary)
        }

        Section("Audio") {
          LabeledContent("Decoded", value: "\(stats.decodedAudio)")
          LabeledContent("Played", value: "\(stats.playedAudioBuffers)")
          LabeledContent("Lost", value: "\(stats.lostAudioBuffers)")
            .foregroundStyle(stats.lostAudioBuffers > 0 ? .red : .primary)
        }
      } else {
        Section { ProgressView("Waiting for statistics…") }
      }
    }
    .navigationTitle("Statistics")
    .task { try? player.play(url: TestMedia.hls) }
    .onDisappear { player.stop() }
  }
}
