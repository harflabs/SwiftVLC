import SwiftUI
import SwiftVLC

private let readMe = """
HLS works out of the box — pass an `.m3u8` URL to `play(url:)`. `player.statistics` \
reports live input bitrate and decode / display / lost frame counters.
"""

struct StreamingHLSCase: View {
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
        Section("Statistics") {
          LabeledContent("Input bitrate", value: String(format: "%.2f", stats.inputBitrate))
          LabeledContent("Decoded", value: "\(stats.decodedVideo) frames")
          LabeledContent("Displayed", value: "\(stats.displayedPictures)")
          LabeledContent("Lost", value: "\(stats.lostPictures)")
            .foregroundStyle(stats.lostPictures > 0 ? .red : .primary)
        }
      } else {
        Section { ProgressView("Opening stream…") }
      }
    }
    .navigationTitle("HLS streaming")
    .task { try? player.play(url: TestMedia.hls) }
    .onDisappear { player.stop() }
  }
}
