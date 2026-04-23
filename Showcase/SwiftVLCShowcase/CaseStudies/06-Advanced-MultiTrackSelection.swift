import SwiftUI
import SwiftVLC

private let readMe = """
Real-world streams often expose multiple audio languages, subtitle tracks, and \
(for DVB / MPEG-TS) separate programs. `audioTracks`, `subtitleTracks`, and \
`programs` publish each surface; binding their `selected*` siblings to `Picker`s \
is the one-liner picker path. Track lists repopulate on `.tracksChanged` — the \
`@Observable` graph handles the UI refresh.
"""

struct MultiTrackSelectionCase: View {
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

      Section("Audio") {
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

      Section("Subtitles") {
        if player.subtitleTracks.isEmpty {
          Text("No subtitle tracks in this stream.")
            .foregroundStyle(.secondary)
        } else {
          Picker("Track", selection: $bindable.selectedSubtitleTrack) {
            Text("Off").tag(Track?.none)
            ForEach(player.subtitleTracks) { track in
              Text(label(for: track)).tag(Track?.some(track))
            }
          }
        }
      }

      Section("Video variants") {
        if player.videoTracks.isEmpty {
          Text("Loading…").foregroundStyle(.secondary)
        } else {
          ForEach(player.videoTracks) { track in
            HStack {
              Text(track.name).lineLimit(1)
              Spacer()
              if let w = track.width, let h = track.height {
                Text("\(w)×\(h)").foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      Section("Programs") {
        if player.programs.isEmpty {
          Text("No program metadata — stream is not MPEG-TS or DVB.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(player.programs) { program in
            HStack {
              Text(program.name)
              if program.isSelected {
                Text("·  active").foregroundStyle(.tint).font(.caption)
              }
              Spacer()
              if program.isScrambled {
                Image(systemName: "lock.fill").foregroundStyle(.orange)
              }
              Text("#\(program.id)").foregroundStyle(.secondary).font(.caption)
            }
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Multi-track selection")
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
