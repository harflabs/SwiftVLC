import SwiftUI
import SwiftVLC

struct MacAudioChannelsCase: View {
  @State private var player = Player()

  private let stereoModes: [StereoMode] = [.unset, .stereo, .reverseStereo, .left, .right, .dolbySurround, .mono]
  private let mixModes: [MixMode] = [.unset, .stereo, .binaural, .fourPointZero, .fivePointOne, .sevenPointOne]

  var body: some View {
    @Bindable var bindable = player

    MacShowcaseContent(
      title: "Audio Channels",
      summary: "Control stereo routing and surround downmixing from regular SwiftUI pickers.",
      usage: "Pick stereo and mix modes while playback runs to see how Player routes channels and reports audio track availability."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Channel Modes") {
          Picker("Stereo", selection: $bindable.stereoMode) {
            ForEach(stereoModes, id: \.self) { mode in
              Text(mode.description.capitalized).tag(mode)
            }
          }
          Picker("Mix", selection: $bindable.mixMode) {
            ForEach(mixModes, id: \.self) { mode in
              Text(mode.description.capitalized).tag(mode)
            }
          }
        }
      }
    } sidebar: {
      MacSection(title: "Current") {
        MacMetricGrid {
          MacMetricRow(title: "Stereo", value: player.stereoMode.description)
          MacMetricRow(title: "Mix", value: player.mixMode.description)
          MacMetricRow(title: "Audio Tracks", value: "\(player.audioTracks.count)")
        }
      }
      MacLibrarySurface(symbols: ["player.stereoMode", "player.mixMode"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
