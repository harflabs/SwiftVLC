import SwiftUI
import SwiftVLC

struct MacAudioTracksCase: View {
  @State private var player = Player()

  var body: some View {
    @Bindable var bindable = player

    MacShowcaseContent(
      title: "Audio Tracks",
      summary: "Bind selectedAudioTrack to a picker and let the published audioTracks list update as media opens.",
      usage: "Open media with multiple tracks, choose an audio track from the picker, and confirm the published track list updates."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Audio Track") {
          Picker("Track", selection: $bindable.selectedAudioTrack) {
            Text("Off").tag(Track?.none)
            ForEach(player.audioTracks) { track in
              Text(label(for: track)).tag(Track?.some(track))
            }
          }
          .disabled(player.audioTracks.isEmpty)
        }
      }
    } sidebar: {
      MacSection(title: "Tracks") {
        if player.audioTracks.isEmpty {
          MacPlaceholderRow(text: "Waiting for audio tracks...")
        } else {
          ForEach(player.audioTracks) { track in
            HStack {
              Text(label(for: track))
              Spacer()
              if track.isSelected {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
              }
            }
          }
        }
      }
      MacLibrarySurface(symbols: ["player.audioTracks", "player.selectedAudioTrack"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private func label(for track: Track) -> String {
    if let language = track.language, !language.isEmpty {
      return "\(track.name) (\(language))"
    }
    return track.name
  }
}
