import SwiftUI
import SwiftVLC

struct NowPlayingControls: View {
  let player: Player

  var body: some View {
    VStack(spacing: 24) {
      SeekRow(player: player)
      TransportRow(player: player)
      VolumeRow(player: player)
    }
  }
}

private struct SeekRow: View {
  let player: Player

  var body: some View {
    VStack(spacing: 6) {
      Slider(
        value: Binding(
          get: { player.position },
          set: { try? player.seek(to: PlaybackPosition($0)) }
        ),
        in: 0...1
      )

      HStack {
        Text(format(player.currentTime))
          .accessibilityIdentifier(AccessibilityID.MusicPlayer.currentTime)
        Spacer()
        Text(format(player.duration ?? .zero))
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
    }
  }

  private func format(_ duration: Duration) -> String {
    let seconds = Int(duration.components.seconds)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

private struct TransportRow: View {
  let player: Player

  var body: some View {
    HStack(spacing: 40) {
      Button {
        try? player.seek(by: .seconds(-15))
      } label: {
        Image(systemName: "gobackward.15").font(.title)
      }
      #if targetEnvironment(macCatalyst)
      .keyboardShortcut(.leftArrow, modifiers: [])
      #endif

      Button {
        player.togglePlayPause()
      } label: {
        Image(systemName: player.isPlaybackRequestedActive ? "pause.circle.fill" : "play.circle.fill")
          .font(.system(size: 64))
          .contentTransition(.symbolEffect(.replace))
      }
      .accessibilityIdentifier(AccessibilityID.MusicPlayer.playPauseButton)
      .accessibilityLabel(player.isPlaybackRequestedActive ? "Pause" : "Play")
      #if targetEnvironment(macCatalyst)
        .keyboardShortcut(.space, modifiers: [])
      #endif

      Button {
        try? player.seek(by: .seconds(15))
      } label: {
        Image(systemName: "goforward.15").font(.title)
      }
      #if targetEnvironment(macCatalyst)
      .keyboardShortcut(.rightArrow, modifiers: [])
      #endif
    }
    .buttonStyle(.plain)
  }
}

private struct VolumeRow: View {
  let player: Player

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "speaker.fill")
        .foregroundStyle(.secondary)

      Slider(
        value: Binding(
          get: { player.volume },
          set: { try? player.setAudioVolume(Volume($0)) }
        ),
        in: 0...1.25
      )

      Image(systemName: "speaker.wave.3.fill")
        .foregroundStyle(.secondary)
    }
  }
}
