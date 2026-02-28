#if os(macOS)
import SwiftUI
import SwiftVLC

extension PolishedPlayerDemo {
  func macOSOverlay(player: Player) -> some View {
    MacOSOverlayContent(
      player: player,
      showControls: showControls,
      onMouseActivity: { showControlsTemporarily() },
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

private struct MacOSOverlayContent: View {
  @Bindable var player: Player
  let showControls: Bool
  let onMouseActivity: () -> Void
  let onInteraction: () -> Void
  let onSeekEditingChanged: (Bool) -> Void

  var body: some View {
    ZStack {
      // Mouse tracking layer — detects any cursor movement
      Color.clear
        .contentShape(.rect)
        .onContinuousHover { phase in
          if case .active = phase {
            onMouseActivity()
          }
        }

      PlayerLoadingOverlay(player: player)

      if showControls {
        controlsOverlay
          .transition(.opacity)
      }
    }
    .onKeyPress(.space) {
      player.togglePlayPause()
      onInteraction()
      return .handled
    }
    .onKeyPress(.leftArrow) {
      player.seek(by: .seconds(-10))
      onInteraction()
      return .handled
    }
    .onKeyPress(.rightArrow) {
      player.seek(by: .seconds(10))
      onInteraction()
      return .handled
    }
    .onKeyPress("m") {
      player.isMuted.toggle()
      onInteraction()
      return .handled
    }
    .focusable()
  }

  private var controlsOverlay: some View {
    VStack {
      // Top bar
      HStack {
        Text("Big Buck Bunny")
          .font(.headline)
        Spacer()
        trackMenus
        aspectRatioMenu
      }
      .padding(.horizontal)
      .padding(.top)
      .background(alignment: .top) { GradientOverlay.top }

      Spacer()

      // Center transport
      centerTransport

      Spacer()

      // Bottom bar — seek slider with time, volume, and rate in one row below
      VStack(spacing: 4) {
        SeekBar(player: player, showTimeLabels: false, onEditingChanged: onSeekEditingChanged)
        HStack {
          Text(player.currentTime.formatted)
            .monospacedDigit()
            .font(.caption)
            .contentTransition(.numericText())

          volumeSlider

          Spacer()

          rateMenu

          Text(remaining.remainingFormatted)
            .monospacedDigit()
            .font(.caption)
            .contentTransition(.numericText())
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
      Button {
        player.seek(by: .seconds(-10))
        onInteraction()
      } label: {
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
      Button {
        player.seek(by: .seconds(10))
        onInteraction()
      } label: {
        Image(systemName: "goforward.10")
          .font(.title)
      }
    }
    .buttonStyle(.plain)
  }

  private var volumeSlider: some View {
    HStack(spacing: 4) {
      Button {
        player.isMuted.toggle()
        onInteraction()
      } label: {
        Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(.plain)

      Slider(value: Binding(
        get: { Double(player.volume) },
        set: { player.volume = Float($0); onInteraction() }
      ), in: 0...1.25)
        .frame(width: 80)
    }
    .font(.caption)
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
    .menuStyle(.borderlessButton)
    .fixedSize()
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
      Label("Tracks", systemImage: "captions.bubble")
        .labelStyle(.iconOnly)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(player.audioTracks.isEmpty && player.subtitleTracks.isEmpty)
  }

  private var aspectRatioMenu: some View {
    Menu {
      Button("Default") { player.aspectRatio = .default; onInteraction() }
      Button("Fill") { player.aspectRatio = .fill; onInteraction() }
      Button("16:9") { player.aspectRatio = .ratio(16, 9); onInteraction() }
      Button("4:3") { player.aspectRatio = .ratio(4, 3); onInteraction() }
    } label: {
      Label("Aspect Ratio", systemImage: "aspectratio")
        .labelStyle(.iconOnly)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var remaining: Duration {
    guard let duration = player.duration else { return .zero }
    let left = duration - player.currentTime
    return left < .zero ? .zero : left
  }
}
#endif
