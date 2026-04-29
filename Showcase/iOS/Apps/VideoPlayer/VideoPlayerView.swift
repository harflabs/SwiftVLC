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
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .onTapGesture { visibility.screenTapped(isPlaying: player.isPlaying) }
    .task(id: visibility.autoHideID) {
      await visibility.autoHideTask()
    }
    .task { try? player.play(url: url) }
    .onDisappear { viewDisappeared() }
    .onChange(of: player.isPlaying) { _, playing in
      visibility.playerIsPlayingChanged(to: playing)
    }
  }

  private func viewDisappeared() {
    visibility.viewDisappeared()
    player.stop()
  }
}

@Observable
@MainActor
private final class ControlsVisibilityModel {
  private(set) var isVisible = true
  private(set) var autoHideID: UUID?

  func screenTapped(isPlaying: Bool) {
    withAnimation { isVisible.toggle() }
    autoHideID = isVisible && isPlaying ? UUID() : nil
  }

  func playerIsPlayingChanged(to playing: Bool) {
    autoHideID = playing && isVisible ? UUID() : nil
  }

  func viewDisappeared() {
    autoHideID = nil
  }

  func autoHideTask() async {
    guard autoHideID != nil else { return }
    try? await Task.sleep(for: .seconds(4))
    if !Task.isCancelled {
      withAnimation { isVisible = false }
      autoHideID = nil
    }
  }
}
