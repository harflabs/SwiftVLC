import SwiftUI
import SwiftVLC

struct TVAudioTracksCase: View {
  @State private var player = Player()

  var body: some View {
    TVShowcaseContent(
      title: "Audio Tracks",
      summary: "Bind selectedAudioTrack to remote-friendly choices and let the published audioTracks list update as media opens.",
      usage: "Open media with multiple tracks, choose an audio track with the remote, and confirm the published track list updates."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
        TVSection(title: "Audio Track", isFocusable: player.audioTracks.isEmpty) {
          if player.audioTracks.isEmpty {
            TVPlaceholderRow(text: "Waiting for audio tracks...")
          } else {
            TVChoiceGrid {
              TVChoiceButton(
                title: "Off",
                isSelected: player.audioTracks.allSatisfy { !$0.isSelected }
              ) {
                player.selectedAudioTrack = nil
              }

              ForEach(player.audioTracks) { track in
                TVChoiceButton(
                  title: track.name,
                  subtitle: subtitle(for: track),
                  isSelected: track.isSelected
                ) {
                  player.selectedAudioTrack = track
                }
              }
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Tracks", isFocusable: true) {
        if player.audioTracks.isEmpty {
          TVPlaceholderRow(text: "Waiting for audio tracks...")
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
      TVLibrarySurface(symbols: ["player.audioTracks", "player.selectedAudioTrack"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private func label(for track: Track) -> String {
    if let language = track.language, !language.isEmpty {
      return "\(track.name) (\(language))"
    }
    return track.name
  }

  private func subtitle(for track: Track) -> String? {
    guard let language = track.language, !language.isEmpty else { return nil }
    return language
  }
}
