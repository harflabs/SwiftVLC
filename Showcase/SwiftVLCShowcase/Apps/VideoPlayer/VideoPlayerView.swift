import SwiftUI
import SwiftVLC

struct VideoPlayerView: View {
  let url: URL
  let title: String

  @State private var player = Player()
  @State private var visibility = ControlsVisibilityModel()

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      VideoView(player)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()

      if visibility.isVisible {
        VideoPlayerControls(player: player, title: title)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    #if os(iOS)
      .statusBarHidden(true)
      .persistentSystemOverlays(.hidden)
    #endif
    #if !os(tvOS)
    .onTapGesture { visibility.screenTapped(isPlaying: player.isPlaying) }
    #endif
    #if os(tvOS)
    .onPlayPauseCommand { player.togglePlayPause() }
    .onMoveCommand { direction in moveCommand(direction) }
    #endif
    .task { try? player.play(url: url) }
    .onDisappear { viewDisappeared() }
    .onChange(of: player.isPlaying) { _, playing in
      visibility.playerIsPlayingChanged(to: playing)
    }
  }

  private func viewDisappeared() {
    visibility.tearDown()
    player.stop()
  }

  #if os(tvOS)
  private func moveCommand(_ direction: MoveCommandDirection) {
    switch direction {
    case .left: player.seek(by: .seconds(-10))
    case .right: player.seek(by: .seconds(10))
    default: break
    }
  }
  #endif
}

/// Auto-hides the player controls after 4 seconds of idle playback,
/// re-arming the timer on each user tap. Lives outside the view so the
/// state machine (visibility flag + pending hide task + interactions
/// with `isPlaying`) is testable in isolation.
@Observable
@MainActor
private final class ControlsVisibilityModel {
  private(set) var isVisible = true

  @ObservationIgnored
  private var hideTask: Task<Void, Never>?

  func screenTapped(isPlaying: Bool) {
    hideTask?.cancel()
    withAnimation { isVisible.toggle() }
    if isVisible, isPlaying {
      scheduleHide()
    }
  }

  func playerIsPlayingChanged(to playing: Bool) {
    if playing, isVisible {
      scheduleHide()
    } else if !playing {
      hideTask?.cancel()
    }
  }

  func tearDown() {
    hideTask?.cancel()
  }

  private func scheduleHide() {
    hideTask?.cancel()
    hideTask = Task {
      try? await Task.sleep(for: .seconds(4))
      if !Task.isCancelled {
        withAnimation { isVisible = false }
      }
    }
  }
}
