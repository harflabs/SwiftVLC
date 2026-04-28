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
    @Bindable var bindable = player
    VStack(spacing: 6) {
      Slider(value: $bindable.position, in: 0...1)

      HStack {
        Text(format(player.currentTime))
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
        player.seek(by: .seconds(-15))
      } label: {
        Image(systemName: "gobackward.15").font(.title)
      }
      #if targetEnvironment(macCatalyst)
      .keyboardShortcut(.leftArrow, modifiers: [])
      #endif

      Button {
        player.togglePlayPause()
      } label: {
        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
          .font(.system(size: 64))
          .contentTransition(.symbolEffect(.replace))
      }
      #if targetEnvironment(macCatalyst)
      .keyboardShortcut(.space, modifiers: [])
      #endif

      Button {
        player.seek(by: .seconds(15))
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
    @Bindable var bindable = player
    HStack(spacing: 12) {
      Image(systemName: "speaker.fill")
        .foregroundStyle(.secondary)

      Slider(value: $bindable.volume, in: 0...1.25)

      Image(systemName: "speaker.wave.3.fill")
        .foregroundStyle(.secondary)
    }
  }
}
