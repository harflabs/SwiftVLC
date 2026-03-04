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
          .font(.title2)
        Spacer()
      }
      .padding(.horizontal, 64)
      .padding(.top, 48)
      .background(alignment: .top) { GradientOverlay.top }

      Spacer()

      // Center transport
      HStack(spacing: 80) {
        Button {
          player.seek(by: .seconds(-10))
          onInteraction()
        } label: {
          Image(systemName: "gobackward.10")
            .font(.system(size: 46))
        }
        .focused($focusedControl, equals: .skipBack)

        Button {
          player.togglePlayPause()
          onInteraction()
        } label: {
          Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 64))
            .contentTransition(.symbolEffect(.replace))
        }
        .focused($focusedControl, equals: .playPause)

        Button {
          player.seek(by: .seconds(10))
          onInteraction()
        } label: {
          Image(systemName: "goforward.10")
            .font(.system(size: 46))
        }
        .focused($focusedControl, equals: .skipForward)
      }
      .buttonStyle(.plain)

      Spacer()

      // Bottom bar
      VStack(spacing: 12) {
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule()
              .fill(.white.opacity(0.3))
              .frame(height: 6)
            Capsule()
              .fill(Color.accentColor)
              .frame(width: max(0, geo.size.width * player.position), height: 6)
          }
        }
        .frame(height: 6)
        HStack {
          Text(player.currentTime.formatted)
            .contentTransition(.numericText())
          Spacer()
          Text(remaining.remainingFormatted)
            .contentTransition(.numericText())
        }
        .monospacedDigit()
        .font(.body)
      }
      .padding(.horizontal, 64)
      .padding(.bottom, 48)
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
