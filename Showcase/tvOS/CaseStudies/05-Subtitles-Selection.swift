import SwiftUI
import SwiftVLC

struct TVSubtitlesSelectionCase: View {
  @State private var player = Player()

  var body: some View {
    TVShowcaseContent(
      title: "Subtitle Selection",
      summary: "Read subtitleTracks as media opens and bind selectedSubtitleTrack to remote-friendly choices.",
      usage: "Choose a subtitle track after media loads and verify selectedSubtitleTrack reflects the choice."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Subtitles", isFocusable: player.subtitleTracks.isEmpty) {
          if player.subtitleTracks.isEmpty {
            TVPlaceholderRow(text: "No subtitle tracks found yet.")
          } else {
            TVChoiceGrid {
              TVChoiceButton(
                title: "Off",
                isSelected: player.subtitleTracks.allSatisfy { !$0.isSelected }
              ) {
                player.selectedSubtitleTrack = nil
              }

              ForEach(player.subtitleTracks) { track in
                TVChoiceButton(
                  title: track.name,
                  subtitle: subtitle(for: track),
                  isSelected: track.isSelected
                ) {
                  player.selectedSubtitleTrack = track
                }
              }
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Tracks", isFocusable: true) {
        if player.subtitleTracks.isEmpty {
          TVPlaceholderRow(text: "No subtitle tracks found yet.")
        } else {
          ForEach(player.subtitleTracks) { track in
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
      TVLibrarySurface(symbols: ["player.subtitleTracks", "player.selectedSubtitleTrack"])
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
