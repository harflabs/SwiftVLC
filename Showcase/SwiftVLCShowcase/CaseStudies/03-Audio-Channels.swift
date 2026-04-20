import SwiftUI
import SwiftVLC

private let readMe = """
`stereoMode` chooses how stereo channels are blended (mono, reverse, left/right-only). \
`mixMode` controls surround downmixing (stereo, binaural, 5.1, 7.1).
"""

struct AudioChannelsCase: View {
  @State private var player = Player()

  var body: some View {
    @Bindable var bindable = player

    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Stereo") {
        Picker("Mode", selection: $bindable.stereoMode) {
          Text("Unset").tag(StereoMode.unset)
          Text("Stereo").tag(StereoMode.stereo)
          Text("Reverse").tag(StereoMode.reverseStereo)
          Text("Left").tag(StereoMode.left)
          Text("Right").tag(StereoMode.right)
          Text("Dolby Surround").tag(StereoMode.dolbySurround)
          Text("Mono").tag(StereoMode.mono)
        }
      }

      Section("Mix") {
        Picker("Mode", selection: $bindable.mixMode) {
          Text("Unset").tag(MixMode.unset)
          Text("Stereo").tag(MixMode.stereo)
          Text("Binaural").tag(MixMode.binaural)
          Text("4.0").tag(MixMode.fourPointZero)
          Text("5.1").tag(MixMode.fivePointOne)
          Text("7.1").tag(MixMode.sevenPointOne)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Audio channels")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }
}
