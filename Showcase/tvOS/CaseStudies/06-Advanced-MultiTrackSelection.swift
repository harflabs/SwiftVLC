import SwiftUI
import SwiftVLC

struct TVMultiTrackSelectionCase: View {
  @State private var player = Player()

  var body: some View {
    TVShowcaseContent(
      title: "Track Selection",
      summary: "Read the published track lists and bind selectedAudioTrack / selectedSubtitleTrack to TV choices.",
      usage: "Use the audio and subtitle choices together to test simultaneous selected track bindings."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
        TVSection(title: "Selection", isFocusable: player.audioTracks.isEmpty && player.subtitleTracks.isEmpty) {
          VStack(alignment: .leading, spacing: 22) {
            trackChoices(
              title: "Audio",
              tracks: player.audioTracks,
              emptyText: "Waiting for audio tracks..."
            ) { track in
              player.selectedAudioTrack = track
            }

            Divider()

            trackChoices(
              title: "Subtitles",
              tracks: player.subtitleTracks,
              emptyText: "No subtitle tracks found yet."
            ) { track in
              player.selectedSubtitleTrack = track
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Tracks", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Audio", value: "\(player.audioTracks.count)")
          TVMetricRow(title: "Video", value: "\(player.videoTracks.count)")
          TVMetricRow(title: "Subtitles", value: "\(player.subtitleTracks.count)")
        }
      }

      TVSection(title: "Video variants", isFocusable: true) {
        ForEach(player.videoTracks) { track in
          HStack {
            Text(track.name)
              .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text(resolution(for: track))
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }

  private func trackChoices(
    title: String,
    tracks: [Track],
    emptyText: String,
    select: @escaping (Track?) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)

      if tracks.isEmpty {
        TVPlaceholderRow(text: emptyText)
      } else {
        TVChoiceGrid {
          TVChoiceButton(
            title: "Off",
            isSelected: tracks.allSatisfy { !$0.isSelected }
          ) {
            select(nil)
          }

          ForEach(tracks) { track in
            TVChoiceButton(
              title: track.name,
              subtitle: subtitle(for: track),
              isSelected: track.isSelected
            ) {
              select(track)
            }
          }
        }
      }
    }
  }

  private func subtitle(for track: Track) -> String? {
    guard let language = track.language, !language.isEmpty else { return nil }
    return language
  }

  private func resolution(for track: Track) -> String {
    guard let width = track.width, let height = track.height else { return "Unknown" }
    return "\(width)x\(height)"
  }
}
