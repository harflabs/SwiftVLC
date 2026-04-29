import Foundation
import SwiftUI
import SwiftVLC

struct SimplePlaybackView: View {
  @State private var player = Player()
  @State private var playbackError: String?

  var body: some View {
    VStack(spacing: 18) {
      header

      VideoView(player)
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier(AccessibilityID.SimplePlayback.videoView)

      controls
    }
    .padding(24)
    .task { startPlayback() }
    .onDisappear { player.stop() }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Simple Playback")
        .font(.title2.bold())

      Spacer()

      Label(player.state.description.capitalized, systemImage: "waveform")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }
  }

  private var controls: some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        Button(action: playPauseButtonTapped) {
          Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(AccessibilityID.SimplePlayback.playPauseButton)

        Button(action: stopButtonTapped) {
          Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(.bordered)

        Spacer()

        Text(Self.format(player.currentTime))
          .monospacedDigit()
          .accessibilityIdentifier(AccessibilityID.SimplePlayback.currentTime)

        Text("/")
          .foregroundStyle(.tertiary)

        Text(player.duration.map(Self.format) ?? "--:--")
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .accessibilityIdentifier(AccessibilityID.SimplePlayback.duration)
      }

      ProgressView(value: playbackProgress)
        .progressViewStyle(.linear)

      if let playbackError {
        Text(playbackError)
          .font(.footnote)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var playbackProgress: Double {
    min(max(player.position, 0), 1)
  }

  private func startPlayback() {
    do {
      try player.play(url: VisionTestMedia.demo)
      playbackError = nil
    } catch {
      playbackError = "Unable to play bundled demo media."
    }
  }

  private func playPauseButtonTapped() {
    player.togglePlayPause()
  }

  private func stopButtonTapped() {
    player.stop()
  }

  private static func format(_ duration: Duration) -> String {
    let seconds = max(0, Int(duration.components.seconds))
    if seconds >= 3600 {
      return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

private enum VisionTestMedia {
  static var demo: URL {
    if let override = LaunchArguments.fixtureURLValue { return override }
    guard let url = Bundle.main.url(forResource: "demo", withExtension: "mkv") else {
      preconditionFailure("Missing bundled media resource: demo.mkv")
    }
    return url
  }
}
