import SwiftUI
import SwiftVLC

struct TVAudioChannelsCase: View {
  @State private var player = Player()

  private let stereoModes: [StereoMode] = [.unset, .stereo, .reverseStereo, .left, .right, .dolbySurround, .mono]
  private let mixModes: [MixMode] = [.unset, .stereo, .binaural, .fourPointZero, .fivePointOne, .sevenPointOne]

  var body: some View {
    TVShowcaseContent(
      title: "Audio Channels",
      summary: "Control stereo routing and surround downmixing with remote-friendly channel choices.",
      usage: "Choose stereo and mix modes while playback runs to see how Player routes channels and reports audio track availability."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
        TVSection(title: "Channel Modes") {
          VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
              Text("Stereo")
                .font(.headline)

              TVChoiceGrid {
                ForEach(stereoModes, id: \.self) { mode in
                  TVChoiceButton(
                    title: mode.description.capitalized,
                    isSelected: player.stereoMode == mode
                  ) {
                    player.stereoMode = mode
                  }
                }
              }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
              Text("Mix")
                .font(.headline)

              TVChoiceGrid {
                ForEach(mixModes, id: \.self) { mode in
                  TVChoiceButton(
                    title: mode.description.capitalized,
                    isSelected: player.mixMode == mode
                  ) {
                    player.mixMode = mode
                  }
                }
              }
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Current", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Stereo", value: player.stereoMode.description)
          TVMetricRow(title: "Mix", value: player.mixMode.description)
          TVMetricRow(title: "Audio Tracks", value: "\(player.audioTracks.count)")
        }
      }
      TVLibrarySurface(symbols: ["player.stereoMode", "player.mixMode"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
