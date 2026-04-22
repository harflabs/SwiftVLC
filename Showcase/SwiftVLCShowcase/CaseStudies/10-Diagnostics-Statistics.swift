import SwiftUI
import SwiftVLC

private let readMe = """
`player.statistics` exposes live input, demux, decoder, and output counters. Useful \
for debugging streaming, frame drops, and codec behavior.
"""

struct StatisticsCase: View {
  @State private var player = Player()

  var body: some View {
    // `player.statistics` is a computed property that isn't itself
    // @Observable — it snapshots libVLC counters on demand. For SwiftUI
    // to re-run this body as stats evolve, the body must read at least
    // one observed property that updates during playback. `currentTime`
    // ticks every ~250ms via `.timeChanged` events, which is exactly the
    // cadence we want for a live stats panel.
    _ = player.currentTime

    return Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Statistics.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Statistics.playPauseButton)
      }

      if let stats = player.statistics {
        Section("Input") {
          statRow("Read", value: "\(stats.readBytes) bytes", id: AccessibilityID.Statistics.readBytes)
          statRow("Bitrate", value: String(format: "%.2f", stats.inputBitrate), id: AccessibilityID.Statistics.inputBitrate)
        }

        Section("Demux") {
          statRow("Read", value: "\(stats.demuxReadBytes) bytes", id: AccessibilityID.Statistics.demuxReadBytes)
          statRow("Bitrate", value: String(format: "%.2f", stats.demuxBitrate), id: AccessibilityID.Statistics.demuxBitrate)
          statRow("Corrupted", value: "\(stats.demuxCorrupted)", id: AccessibilityID.Statistics.demuxCorrupted)
          statRow("Discontinuity", value: "\(stats.demuxDiscontinuity)", id: AccessibilityID.Statistics.demuxDiscontinuity)
        }

        Section("Video") {
          statRow("Decoded", value: "\(stats.decodedVideo)", id: AccessibilityID.Statistics.decodedVideo)
          statRow("Displayed", value: "\(stats.displayedPictures)", id: AccessibilityID.Statistics.displayedPictures)
          statRow(
            "Late",
            value: "\(stats.latePictures)",
            id: AccessibilityID.Statistics.latePictures,
            tint: stats.latePictures > 0 ? .orange : .primary
          )
          statRow(
            "Lost",
            value: "\(stats.lostPictures)",
            id: AccessibilityID.Statistics.lostPictures,
            tint: stats.lostPictures > 0 ? .red : .primary
          )
        }

        Section("Audio") {
          statRow("Decoded", value: "\(stats.decodedAudio)", id: AccessibilityID.Statistics.decodedAudio)
          statRow("Played", value: "\(stats.playedAudioBuffers)", id: AccessibilityID.Statistics.playedAudioBuffers)
          statRow(
            "Lost",
            value: "\(stats.lostAudioBuffers)",
            id: AccessibilityID.Statistics.lostAudioBuffers,
            tint: stats.lostAudioBuffers > 0 ? .red : .primary
          )
        }
      } else {
        Section {
          ProgressView("Waiting for statistics…")
            .accessibilityIdentifier(AccessibilityID.Statistics.waitingLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Statistics")
    .task { try? player.play(url: TestMedia.hls) }
    .onDisappear { player.stop() }
  }

  /// `LabeledContent` merges label + value into a single accessibility
  /// element, which defeats per-value XCUITest queries. A plain HStack
  /// keeps each value's `XCUIElement.label` identical to its visible
  /// string — same approach as the Player State showcase.
  private func statRow(
    _ title: String,
    value: String,
    id: String,
    tint: Color = .primary
  ) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(tint)
        .accessibilityIdentifier(id)
    }
  }
}
