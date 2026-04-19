import SwiftUI
import SwiftVLC

/// Demonstrates MediaListPlayer with multiple items,
/// playback modes, and now-playing state.
struct PlaylistDemo: View {
  @State private var player: Player?
  @State private var listPlayer: MediaListPlayer?
  @State private var items: [PlaylistItem] = []
  @State private var error: Error?

  var body: some View {
    Group {
      #if os(tvOS)
      tvOSBody
      #else
      defaultBody
      #endif
    }
    .task {
      await setupPlaylist()
    }
    .onDisappear {
      listPlayer?.stop()
      player?.stop()
    }
  }

  // MARK: - iOS / macOS

  #if !os(tvOS)
  private var defaultBody: some View {
    #if targetEnvironment(macCatalyst)
    catalystBody
    #else
    phoneBody
    #endif
  }

  private var phoneBody: some View {
    VStack(spacing: .zero) {
      if let player {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .clipShape(.rect(cornerRadius: 12))
          .clipped()
          .padding()

        PlayerStatusBar(player: player)
          .padding(.horizontal)
      } else if error != nil {
        DemoErrorView(
          title: "Playlist Failed",
          message: "Could not set up the playlist.",
          retry: { Task { await setupPlaylist() } }
        )
      } else {
        ProgressView("Loading playlist...")
          .frame(height: 200)
      }

      trackList

      if let player, let listPlayer {
        transportControls(player: player, listPlayer: listPlayer)
      }
    }
    .navigationTitle("Playlist")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  private var catalystBody: some View {
    HStack(spacing: 0) {
      // Left: video + transport
      VStack(spacing: 16) {
        if let player {
          VideoView(player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .clipped()

          PlayerStatusBar(player: player)
        } else if error != nil {
          ContentUnavailableView(
            "Playlist Failed",
            systemImage: "exclamationmark.triangle",
            description: Text("Could not set up the playlist.")
          )
        } else {
          ProgressView("Loading playlist...")
            .frame(maxHeight: .infinity)
        }

        if let player, let listPlayer {
          transportControls(player: player, listPlayer: listPlayer)
        }
      }
      .frame(maxWidth: .infinity)
      .padding()

      // Right: track list
      trackList
        .frame(width: 300)
    }
    .navigationTitle("Playlist")
  }
  #endif

  // MARK: - tvOS — Horizontal layout

  #if os(tvOS)
  private var tvOSBody: some View {
    HStack(spacing: 0) {
      // Left: video + transport
      VStack(spacing: 24) {
        if let player {
          VideoView(player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 16))
            .clipped()

          PlayerStatusBar(player: player)
            .font(.body)
        } else if error != nil {
          ContentUnavailableView(
            "Playlist Failed",
            systemImage: "exclamationmark.triangle",
            description: Text("Could not set up the playlist.")
          )
        } else {
          ProgressView("Loading playlist...")
            .frame(maxHeight: .infinity)
        }

        if let player, let listPlayer {
          transportControls(player: player, listPlayer: listPlayer)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(40)

      // Right: track list
      trackList
        .frame(width: 500)
    }
    .navigationTitle("Playlist")
  }
  #endif

  // MARK: - Shared Components

  private var trackList: some View {
    List(items) { item in
      Button {
        playItem(at: item.index)
      } label: {
        HStack {
          if item.index == selectedIndex {
            Image(systemName: "speaker.wave.2.fill")
              .foregroundStyle(.tint)
          } else {
            Image(systemName: "music.note")
              .foregroundStyle(.secondary)
          }
          VStack(alignment: .leading) {
            Text(item.title)
              .font(.body)
              .foregroundStyle(item.index == selectedIndex ? .primary : .secondary)
            if let duration = item.duration {
              Text(duration.formatted)
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }
        }
      }
      #if !os(tvOS)
      .buttonStyle(.plain)
      #endif
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func transportControls(player: Player, listPlayer: MediaListPlayer) -> some View {
    VStack(spacing: 8) {
      HStack(spacing: 24) {
        Button {
          try? listPlayer.previous()
        } label: {
          Label("Previous", systemImage: "backward.fill")
            .labelStyle(.iconOnly)
            .font(.title2)
        }

        Button {
          player.togglePlayPause()
        } label: {
          Label(
            player.isPlaying ? "Pause" : "Play",
            systemImage: player.isPlaying ? "pause.fill" : "play.fill"
          )
          .labelStyle(.iconOnly)
          .font(.title)
          .contentTransition(.symbolEffect(.replace))
        }

        Button {
          try? listPlayer.next()
        } label: {
          Label("Next", systemImage: "forward.fill")
            .labelStyle(.iconOnly)
            .font(.title2)
        }
      }
      .buttonStyle(.plain)

      Picker("Mode", selection: Binding(
        get: { listPlayer.playbackMode },
        set: { listPlayer.playbackMode = $0 }
      )) {
        Label("Play Once", systemImage: "arrow.right")
          .tag(PlaybackMode.default)
        Label("Loop All", systemImage: "repeat")
          .tag(PlaybackMode.loop)
        Label("Repeat One", systemImage: "repeat.1")
          .tag(PlaybackMode.repeat)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
    }
    .padding()
  }

  private func setupPlaylist() async {
    // Tear down the previous playlist/session before rebuilding it so a
    // retry doesn't leave old playback or item state wired up.
    listPlayer?.stop()
    player?.stop()
    listPlayer = nil
    player = nil
    items = []
    error = nil
    do {
      let sources = PlaylistSource.defaults
      let p = Player()
      player = p

      let lp = MediaListPlayer()
      lp.mediaPlayer = p
      listPlayer = lp

      let list = MediaList()
      items = sources.enumerated().map { index, source in
        PlaylistItem(
          index: index,
          title: source.title,
          duration: nil,
          mrl: source.url.absoluteString
        )
      }

      for source in sources {
        let media = try Media(url: source.url)
        try list.append(media)
      }

      lp.mediaList = list
      lp.play()
    } catch {
      listPlayer?.stop()
      player?.stop()
      listPlayer = nil
      player = nil
      items = []
      self.error = error
    }
  }

  private func playItem(at index: Int) {
    try? listPlayer?.play(at: index)
  }

  private var selectedIndex: Int? {
    guard let mrl = player?.currentMedia?.mrl else { return nil }
    return items.first(where: { $0.mrl == mrl })?.index
  }
}

private struct PlaylistSource {
  let title: String
  let url: URL

  static let defaults: [PlaylistSource] = [
    PlaylistSource(title: "Big Buck Bunny", url: TestMedia.bigBuckBunny),
    PlaylistSource(title: "Sintel", url: TestMedia.sintel),
    PlaylistSource(title: "Elephants Dream", url: TestMedia.elephantsDream)
  ]
}

private struct PlaylistItem: Identifiable {
  let index: Int
  let title: String
  let duration: Duration?
  let mrl: String
  var id: Int {
    index
  }
}
