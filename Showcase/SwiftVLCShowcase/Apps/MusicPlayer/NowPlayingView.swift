import SwiftUI
import SwiftVLC

struct NowPlayingView: View {
  let song: Song

  @State private var player = Player()
  @State private var metadata: Metadata?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 24) {
      HStack {
        Button { dismiss() } label: {
          Image(systemName: "chevron.down")
            .font(.title2.weight(.semibold))
            .padding(10)
            .background(.secondary.opacity(0.2), in: .circle)
        }
        .buttonStyle(.plain)

        Spacer()
      }

      Spacer(minLength: 0)

      Artwork(url: metadata?.artworkURL)

      VStack(spacing: 6) {
        Text(metadata?.title ?? song.title)
          .font(.title2.bold())
          .multilineTextAlignment(.center)
        Text(metadata?.artist ?? song.artist)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      NowPlayingControls(player: player)
    }
    .padding()
    .frame(maxWidth: 520)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      try? player.play(url: song.url)
      if let media = try? Media(url: song.url) {
        metadata = try? await media.parse()
      }
    }
    .onDisappear { player.stop() }
  }
}

private struct Artwork: View {
  let url: URL?

  var body: some View {
    Group {
      if let url {
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let image):
            image.resizable()
          default:
            placeholder
          }
        }
      } else {
        placeholder
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .frame(maxWidth: 360)
    .clipShape(.rect(cornerRadius: 20))
    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
  }

  private var placeholder: some View {
    LinearGradient(
      colors: [.blue.opacity(0.8), .purple.opacity(0.8)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .overlay {
      Image(systemName: "music.note")
        .font(.system(size: 72))
        .foregroundStyle(.white.opacity(0.9))
    }
  }
}
