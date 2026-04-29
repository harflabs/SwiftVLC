import SwiftUI
import SwiftVLC

struct MacSubtitlesSelectionCase: View {
  @State private var player = Player()

  var body: some View {
    @Bindable var bindable = player

    MacShowcaseContent(
      title: "Subtitle Selection",
      summary: "Read subtitleTracks as media opens and bind selectedSubtitleTrack to a native picker.",
      usage: "Choose a subtitle track from the picker after media loads and verify selectedSubtitleTrack reflects the choice."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Subtitles") {
          Picker("Track", selection: $bindable.selectedSubtitleTrack) {
            Text("Off").tag(Track?.none)
            ForEach(player.subtitleTracks) { track in
              Text(label(for: track)).tag(Track?.some(track))
            }
          }
          .disabled(player.subtitleTracks.isEmpty)
        }
      }
    } sidebar: {
      MacSection(title: "Tracks") {
        if player.subtitleTracks.isEmpty {
          MacPlaceholderRow(text: "No subtitle tracks found yet.")
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
      MacLibrarySurface(symbols: ["player.subtitleTracks", "player.selectedSubtitleTrack"])
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
