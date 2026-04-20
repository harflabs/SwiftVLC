import SwiftUI
import SwiftVLC

struct VideoPlayerView: View {
  let url: URL
  let title: String

  @State private var player = Player()
  @State private var showControls = true
  @State private var hideTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      VideoView(player)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()

      if showControls {
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
    .onTapGesture { toggleControls() }
    #endif
    #if os(tvOS)
    .onPlayPauseCommand { player.togglePlayPause() }
    .onMoveCommand { direction in
      switch direction {
      case .left: player.seek(by: .seconds(-10))
      case .right: player.seek(by: .seconds(10))
      default: break
      }
    }
    #endif
    .task { try? player.play(url: url) }
    .onDisappear {
      hideTask?.cancel()
      player.stop()
    }
    .onChange(of: player.isPlaying) { _, playing in
      if playing && showControls {
        scheduleHide()
      } else if !playing {
        hideTask?.cancel()
      }
    }
  }

  private func toggleControls() {
    hideTask?.cancel()
    withAnimation { showControls.toggle() }
    if showControls && player.isPlaying {
      scheduleHide()
    }
  }

  private func scheduleHide() {
    hideTask?.cancel()
    hideTask = Task {
      try? await Task.sleep(for: .seconds(4))
      if !Task.isCancelled {
        withAnimation { showControls = false }
      }
    }
  }
}
