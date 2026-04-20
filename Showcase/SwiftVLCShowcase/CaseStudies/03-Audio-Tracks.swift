import SwiftUI
import SwiftVLC

private let readMe = """
`audioTracks` populates once media is opened. Bind `selectedAudioTrack` to a `Picker` \
to switch streams, or set `nil` to disable audio entirely.
"""

struct AudioTracksCase: View {
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

      Section("Audio tracks") {
        if player.audioTracks.isEmpty {
          Text("Loading…").foregroundStyle(.secondary)
        } else {
          Picker("Track", selection: $bindable.selectedAudioTrack) {
            Text("Off").tag(Track?.none)
            ForEach(player.audioTracks) { track in
              Text(label(for: track)).tag(Track?.some(track))
            }
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Audio tracks")
    .task { try? player.play(url: TestMedia.tearsOfSteel) }
    .onDisappear { player.stop() }
  }

  private func label(for track: Track) -> String {
    if let language = track.language, !language.isEmpty {
      return "\(track.name) (\(language))"
    }
    return track.name
  }
}
