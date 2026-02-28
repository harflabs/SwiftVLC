#if os(iOS)
import SwiftUI
import SwiftVLC

extension PolishedPlayerDemo {
  func iOSOverlay(player: Player) -> some View {
    IOSOverlayContent(
      player: player,
      showControls: showControls,
      onTap: { toggleControlVisibility() },
      onSkipBack: {
        player.seek(by: .seconds(-10))
        showControlsTemporarily()
      },
      onSkipForward: {
        player.seek(by: .seconds(10))
        showControlsTemporarily()
      },
      onInteraction: { showControlsTemporarily() },
      onSeekEditingChanged: { editing in
        isSeeking = editing
        if editing {
          hideTask?.cancel()
        } else {
          scheduleHide()
        }
      }
    )
  }
}

private struct IOSOverlayContent: View {
  @Bindable var player: Player
  let showControls: Bool
  let onTap: () -> Void
  let onSkipBack: () -> Void
  let onSkipForward: () -> Void
  let onInteraction: () -> Void
  let onSeekEditingChanged: (Bool) -> Void

  @State private var skipIndicator: SkipDirection?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      // Tap / double-tap layer
      HStack(spacing: .zero) {
        // Left half — double-tap to skip back
        Color.clear
          .contentShape(.rect)
          .onTapGesture(count: 2) {
            flashSkip(.backward)
            onSkipBack()
          }
          .onTapGesture {
            onTap()
          }

        // Right half — double-tap to skip forward
        Color.clear
          .contentShape(.rect)
          .onTapGesture(count: 2) {
            flashSkip(.forward)
            onSkipForward()
          }
          .onTapGesture {
            onTap()
          }
      }

      // Skip indicator
      if let direction = skipIndicator {
        Label(
          "10s",
          systemImage: direction == .backward ? "gobackward.10" : "goforward.10"
        )
        .font(.title)
        .foregroundStyle(.white)
        .padding()
        .background(.ultraThinMaterial, in: .capsule)
        .transition(.scale.combined(with: .opacity))
        .frame(
          maxWidth: .infinity,
          alignment: direction == .backward ? .leading : .trailing
        )
        .padding(.horizontal)
      }

      // Loading
      PlayerLoadingOverlay(player: player)

      // Controls overlay
      if showControls {
        controlsOverlay
          .transition(.opacity)
      }
    }
  }

  private var controlsOverlay: some View {
    VStack {
      // Top bar
      HStack {
        Button { dismiss() } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.title2)
        }
        Spacer()
        Text("Big Buck Bunny")
          .font(.headline)
        Spacer()
        trackMenus
        aspectRatioButton
      }
      .padding(.horizontal)
      .padding(.top)
      .background(alignment: .top) { GradientOverlay.top }

      Spacer()

      // Center transport
      centerTransport

      Spacer()

      // Bottom bar
      VStack(spacing: 8) {
        SeekBar(player: player, onEditingChanged: onSeekEditingChanged)
        HStack {
          volumeControls
          Spacer()
          rateMenu
        }
      }
      .padding(.horizontal)
      .padding(.bottom)
      .background(alignment: .bottom) { GradientOverlay.bottom }
    }
    .foregroundStyle(.white)
  }

  private var centerTransport: some View {
    HStack(spacing: 40) {
      Button { onSkipBack() } label: {
        Image(systemName: "gobackward.10")
          .font(.title)
      }
      Button {
        player.togglePlayPause()
        onInteraction()
      } label: {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
          .font(.largeTitle)
          .contentTransition(.symbolEffect(.replace))
      }
      Button { onSkipForward() } label: {
        Image(systemName: "goforward.10")
          .font(.title)
      }
    }
    .buttonStyle(.plain)
  }

  private var volumeControls: some View {
    Button {
      player.isMuted.toggle()
      onInteraction()
    } label: {
      Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(.plain)
  }

  private var rateMenu: some View {
    Menu {
      ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
        Button {
          player.rate = Float(rate)
          onInteraction()
        } label: {
          HStack {
            Text("\(rate, specifier: "%.2g")x")
            if abs(player.rate - Float(rate)) < 0.01 {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      Text("\(player.rate, specifier: "%.2g")x")
        .monospacedDigit()
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: .capsule)
    }
  }

  private var trackMenus: some View {
    Menu {
      if !player.audioTracks.isEmpty {
        Section("Audio") {
          ForEach(player.audioTracks) { track in
            Button {
              player.selectedAudioTrack = track
              onInteraction()
            } label: {
              HStack {
                Text(track.name)
                if player.selectedAudioTrack?.id == track.id {
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        }
      }
      if !player.subtitleTracks.isEmpty {
        Section("Subtitles") {
          Button("Off") {
            player.selectedSubtitleTrack = nil
            onInteraction()
          }
          ForEach(player.subtitleTracks) { track in
            Button {
              player.selectedSubtitleTrack = track
              onInteraction()
            } label: {
              HStack {
                Text(track.name)
                if player.selectedSubtitleTrack?.id == track.id {
                  Image(systemName: "checkmark")
                }
              }
            }
          }
        }
      }
    } label: {
      Image(systemName: "captions.bubble")
        .font(.title2)
    }
    .disabled(player.audioTracks.isEmpty && player.subtitleTracks.isEmpty)
  }

  private var aspectRatioButton: some View {
    Menu {
      Button("Default") { player.aspectRatio = .default; onInteraction() }
      Button("Fill") { player.aspectRatio = .fill; onInteraction() }
      Button("16:9") { player.aspectRatio = .ratio(16, 9); onInteraction() }
      Button("4:3") { player.aspectRatio = .ratio(4, 3); onInteraction() }
    } label: {
      Image(systemName: "aspectratio")
        .font(.title2)
    }
  }

  private func flashSkip(_ direction: SkipDirection) {
    withAnimation(.spring(duration: 0.2)) {
      skipIndicator = direction
    }
    Task {
      try? await Task.sleep(for: .seconds(0.6))
      withAnimation { skipIndicator = nil }
    }
  }
}

private enum SkipDirection {
  case backward, forward
}
#endif
