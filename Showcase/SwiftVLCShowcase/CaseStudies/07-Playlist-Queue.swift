import SwiftUI
import SwiftVLC

private let readMe = """
Wrap a `Player` with `MediaListPlayer` to play a queue. `next()` / `previous()` step \
through the list; `playbackMode` controls loop and repeat behavior.
"""

struct PlaylistQueueCase: View {
  @State private var player = Player()
  @State private var listPlayer = MediaListPlayer()
  @State private var list = MediaList()
  @State private var mode: PlaybackMode = .default

  private let sources: [(url: URL, title: String)] = [
    (TestMedia.bigBuckBunny, "Big Buck Bunny"),
    (TestMedia.tearsOfSteel, "Tears of Steel"),
    (TestMedia.hls, "HLS stream")
  ]

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        Button(
          player.isPlaying ? "Pause" : "Play",
          systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill"
        ) { listPlayer.togglePause() }
          .labelStyle(.iconOnly)
          .contentTransition(.symbolEffect(.replace))
          .font(.largeTitle)
          .frame(maxWidth: .infinity, alignment: .center)
      }

      Section("Queue") {
        ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
          Button {
            try? listPlayer.play(at: index)
          } label: {
            Label(source.title, systemImage: "play.fill")
          }
        }
      }

      Section("Mode") {
        Picker("Mode", selection: $mode) {
          Text("Default").tag(PlaybackMode.default)
          Text("Loop").tag(PlaybackMode.loop)
          Text("Repeat").tag(PlaybackMode.repeat)
        }
        .pickerStyle(.segmented)
      }

      Section {
        HStack {
          Button("Previous", systemImage: "backward.fill") { try? listPlayer.previous() }
          Spacer()
          Button("Next", systemImage: "forward.fill") { try? listPlayer.next() }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Playlist queue")
    .task {
      listPlayer.mediaPlayer = player
      listPlayer.mediaList = list
      for source in sources {
        if let media = try? Media(url: source.url) {
          try? list.append(media)
        }
      }
      listPlayer.play()
    }
    .onChange(of: mode) { listPlayer.playbackMode = mode }
    .onDisappear { listPlayer.stop() }
  }
}
