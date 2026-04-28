import SwiftUI
import SwiftVLC

struct VideoPlayerControls: View {
  let player: Player
  let title: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      TopBar(player: player, title: title, dismiss: dismiss)
      Spacer()
      BottomBar(player: player)
    }
    .foregroundStyle(.white)
  }
}

private struct TopBar: View {
  let player: Player
  let title: String
  let dismiss: DismissAction

  private let rates: [Float] = [0.5, 1.0, 1.25, 1.5, 2.0]

  var body: some View {
    @Bindable var bindable = player
    HStack(spacing: 16) {
      Button { dismiss() } label: {
        Image(systemName: "xmark")
          .font(.title2.weight(.semibold))
      }
      #if targetEnvironment(macCatalyst)
      .keyboardShortcut(.escape, modifiers: [])
      #endif

      Text(title)
        .font(.headline)
        .lineLimit(1)

      Spacer()

      Menu {
        if !player.audioTracks.isEmpty {
          Picker("Audio", selection: $bindable.selectedAudioTrack) {
            Text("Off").tag(Track?.none)
            ForEach(player.audioTracks) { track in
              Text(track.name).tag(Track?.some(track))
            }
          }
        }
        if !player.subtitleTracks.isEmpty {
          Picker("Subtitles", selection: $bindable.selectedSubtitleTrack) {
            Text("Off").tag(Track?.none)
            ForEach(player.subtitleTracks) { track in
              Text(track.name).tag(Track?.some(track))
            }
          }
        }
        Picker("Speed", selection: $bindable.rate) {
          ForEach(rates, id: \.self) { rate in
            Text(String(format: "%.2f×", rate)).tag(rate)
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.title2)
      }
    }
    .padding()
    .background(
      LinearGradient(
        colors: [.black.opacity(0.75), .clear],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }
}

private struct BottomBar: View {
  let player: Player

  var body: some View {
    VStack(spacing: 20) {
      SeekRow(player: player)
      TransportRow(player: player)
    }
    .padding()
    .background(
      LinearGradient(
        colors: [.clear, .black.opacity(0.75)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }
}

private struct SeekRow: View {
  let player: Player

  var body: some View {
    @Bindable var bindable = player
    HStack(spacing: 12) {
      Text(format(player.currentTime))
        .font(.caption.monospacedDigit())

      Slider(value: $bindable.position, in: 0...1)

      Text(format(player.duration ?? .zero))
        .font(.caption.monospacedDigit())
    }
  }

  private func format(_ duration: Duration) -> String {
    let total = Int(duration.components.seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
  }
}

private struct TransportRow: View {
  let player: Player

  var body: some View {
    HStack(spacing: 48) {
      Button {
        player.seek(by: .seconds(-10))
      } label: {
        Image(systemName: "gobackward.10").font(.title)
      }
      #if targetEnvironment(macCatalyst)
      .keyboardShortcut(.leftArrow, modifiers: [])
      #endif

      Button {
        player.togglePlayPause()
      } label: {
        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
          .font(.system(size: 60))
          .contentTransition(.symbolEffect(.replace))
      }
      #if targetEnvironment(macCatalyst)
      .keyboardShortcut(.space, modifiers: [])
      #endif

      Button {
        player.seek(by: .seconds(10))
      } label: {
        Image(systemName: "goforward.10").font(.title)
      }
      #if targetEnvironment(macCatalyst)
      .keyboardShortcut(.rightArrow, modifiers: [])
      #endif
    }
    .buttonStyle(.plain)
  }
}
