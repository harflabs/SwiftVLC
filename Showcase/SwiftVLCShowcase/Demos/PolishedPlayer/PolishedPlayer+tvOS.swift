#if os(tvOS)
import SwiftUI
import SwiftVLC

extension PolishedPlayerDemo {
  func tvOSOverlay(player: Player) -> some View {
    TVOSOverlayContent(
      player: player,
      showControls: showControls,
      onInteraction: { showControlsTemporarily() }
    )
  }
}

private struct TVOSOverlayContent: View {
  @Bindable var player: Player
  let showControls: Bool
  let onInteraction: () -> Void

  @FocusState private var focusedControl: TVControl?

  var body: some View {
    ZStack {
      PlayerLoadingOverlay(player: player)

      if showControls {
        controlsOverlay
          .transition(.opacity)
      }
    }
    .onPlayPauseCommand {
      player.togglePlayPause()
      onInteraction()
    }
    .onMoveCommand { direction in
      switch direction {
      case .left:
        player.seek(by: .seconds(-10))
      case .right:
        player.seek(by: .seconds(10))
      default:
        break
      }
      onInteraction()
    }
  }

  private var controlsOverlay: some View {
    VStack {
      // Top bar
      HStack {
        Text("Big Buck Bunny")
          .font(.title3)
        Spacer()
      }
      .padding(.horizontal)
      .padding(.top)
      .background(alignment: .top) { GradientOverlay.top }

      Spacer()

      // Center transport
      HStack(spacing: 60) {
        Button {
          player.seek(by: .seconds(-10))
          onInteraction()
        } label: {
          Image(systemName: "gobackward.10")
            .font(.title)
        }
        .focused($focusedControl, equals: .skipBack)

        Button {
          player.togglePlayPause()
          onInteraction()
        } label: {
          Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            .font(.largeTitle)
            .contentTransition(.symbolEffect(.replace))
        }
        .focused($focusedControl, equals: .playPause)

        Button {
          player.seek(by: .seconds(10))
          onInteraction()
        } label: {
          Image(systemName: "goforward.10")
            .font(.title)
        }
        .focused($focusedControl, equals: .skipForward)
      }
      .buttonStyle(.plain)

      Spacer()

      // Bottom bar
      VStack(spacing: 4) {
        ProgressView(value: player.position, total: 1.0)
          .tint(.accentColor)
        HStack {
          Text(player.currentTime.formatted)
            .contentTransition(.numericText())
          Spacer()
          Text(remaining.remainingFormatted)
            .contentTransition(.numericText())
        }
        .monospacedDigit()
        .font(.caption)
      }
      .padding(.horizontal)
      .padding(.bottom)
      .background(alignment: .bottom) { GradientOverlay.bottom }
    }
    .foregroundStyle(.white)
    .defaultFocus($focusedControl, .playPause)
  }

  private var remaining: Duration {
    guard let duration = player.duration else { return .zero }
    let left = duration - player.currentTime
    return left < .zero ? .zero : left
  }
}

private enum TVControl: Hashable {
  case skipBack, playPause, skipForward
}
#endif
