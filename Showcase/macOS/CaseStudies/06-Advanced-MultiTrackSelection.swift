import SwiftUI
import SwiftVLC

struct MacMultiTrackSelectionCase: View {
  @State private var player = Player()

  var body: some View {
    @Bindable var bindable = player

    MacShowcaseContent(
      title: "Track Selection",
      summary: "Read the published track lists and bind selectedAudioTrack / selectedSubtitleTrack to pickers.",
      usage: "Use the audio and subtitle pickers together to test simultaneous selected track bindings."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Selection") {
          Picker("Audio", selection: $bindable.selectedAudioTrack) {
            Text("Off").tag(Track?.none)
            ForEach(player.audioTracks) { track in
              Text(label(for: track)).tag(Track?.some(track))
            }
          }
          Picker("Subtitles", selection: $bindable.selectedSubtitleTrack) {
            Text("Off").tag(Track?.none)
            ForEach(player.subtitleTracks) { track in
              Text(label(for: track)).tag(Track?.some(track))
            }
          }
        }
      }
    } sidebar: {
      MacSection(title: "Tracks") {
        MacMetricGrid {
          MacMetricRow(title: "Audio", value: "\(player.audioTracks.count)")
          MacMetricRow(title: "Video", value: "\(player.videoTracks.count)")
          MacMetricRow(title: "Subtitles", value: "\(player.subtitleTracks.count)")
        }
      }

      MacSection(title: "Video variants") {
        ForEach(player.videoTracks) { track in
          HStack {
            Text(track.name)
              .lineLimit(1)
            Spacer()
            Text(resolution(for: track))
              .foregroundStyle(.secondary)
          }
        }
      }
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

  private func resolution(for track: Track) -> String {
    guard let width = track.width, let height = track.height else { return "Unknown" }
    return "\(width)x\(height)"
  }
}
