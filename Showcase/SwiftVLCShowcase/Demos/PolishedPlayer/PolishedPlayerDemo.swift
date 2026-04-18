import SwiftUI
import SwiftVLC

struct PolishedPlayerDemo: View {
  @State var player: Player?
  @State var title: String = ""
  @State var showControls = true
  @State var hideTask: Task<Void, Never>?
  @State var isSeeking = false
  @State private var error: Error?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let player {
        VideoView(player)
          .ignoresSafeArea()

        playerOverlay(player)
      } else if error != nil {
        ContentUnavailableView(
          "Playback Failed",
          systemImage: "exclamationmark.triangle",
          description: Text("Could not load the video player.")
        )
      } else {
        ProgressView("Loading player...")
      }
    }
    #if os(iOS)
    .navigationBarHidden(true)
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    #endif
    #if os(macOS)
    .frame(minWidth: 640, minHeight: 400)
    #endif
    .task {
      do {
        let url = TestMedia.bigBuckBunny
        let p = Player()
        player = p
        // Derive a display title from URL immediately; refine with parsed
        // metadata asynchronously so the overlay isn't empty while parsing.
        title = url.deletingPathExtension().lastPathComponent
          .replacingOccurrences(of: "_", with: " ")
        let media = try Media(url: url)
        try p.play(media)
        scheduleHide()
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif

        // Parse the SAME media instance asynchronously (Media is a
        // Sendable reference type, so the player's retain is safe to
        // coexist with our parse call). Reusing avoids a second network
        // fetch for the same URL.
        if
          let parsed = try? await media.parse(),
          let parsedTitle = parsed.title, !parsedTitle.isEmpty {
          title = parsedTitle
        }
      } catch {
        self.error = error
      }
    }
    .onDisappear {
      hideTask?.cancel()
      player?.stop()
      #if os(iOS)
      UIApplication.shared.isIdleTimerDisabled = false
      #endif
    }
    .onChange(of: player?.state) { _, newState in
      // Show controls when playback ends or errors
      if let newState, newState == .stopped || newState == .error {
        withAnimation(.easeInOut(duration: 0.3)) {
          showControls = true
        }
        hideTask?.cancel()
      }
    }
  }

  @ViewBuilder
  private func playerOverlay(_ player: Player) -> some View {
    #if os(iOS)
    iOSOverlay(player: player, title: title)
    #elseif os(macOS)
    macOSOverlay(player: player, title: title)
    #elseif os(tvOS)
    tvOSOverlay(player: player, title: title)
    #endif
  }

  // MARK: - Control Visibility

  func showControlsTemporarily() {
    withAnimation(.easeInOut(duration: 0.3)) {
      showControls = true
    }
    scheduleHide()
  }

  func toggleControlVisibility() {
    if showControls {
      withAnimation(.easeInOut(duration: 0.3)) {
        showControls = false
      }
      hideTask?.cancel()
    } else {
      showControlsTemporarily()
    }
  }

  func scheduleHide() {
    hideTask?.cancel()
    // Don't auto-hide while the user is scrubbing
    guard !isSeeking else { return }
    // Don't auto-hide when playback has ended
    guard player?.isPlaying == true else { return }
    hideTask = Task {
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.3)) {
        showControls = false
      }
    }
  }
}

// MARK: - Loading Overlay

struct PlayerLoadingOverlay: View {
  let player: Player

  var body: some View {
    if isLoading {
      ProgressView()
        .controlSize(.large)
        .tint(.white)
    }
  }

  private var isLoading: Bool {
    switch player.state {
    case .opening, .buffering: true
    default: false
    }
  }
}
