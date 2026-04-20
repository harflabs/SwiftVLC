import SwiftUI
import SwiftVLC

private let readMe = """
`subtitleTracks` lists embedded subtitles. Bind `selectedSubtitleTrack` to a `Picker` \
to enable one, or set `nil` to hide them.
"""

struct SubtitlesSelectionCase: View {
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

      Section("Position") {
        SeekBar(player: player)
      }

      Section("Subtitles") {
        if player.subtitleTracks.isEmpty {
          Text("No subtitle tracks").foregroundStyle(.secondary)
        } else {
          Picker("Track", selection: $bindable.selectedSubtitleTrack) {
            Text("Off").tag(Track?.none)
            ForEach(player.subtitleTracks) { track in
              Text(track.name).tag(Track?.some(track))
            }
          }
        }
      }
    }
    .navigationTitle("Subtitles")
    .task { try? player.play(url: TestMedia.tearsOfSteel) }
    .onDisappear { player.stop() }
  }
}
