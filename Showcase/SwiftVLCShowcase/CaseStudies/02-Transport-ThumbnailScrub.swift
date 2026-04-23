import SwiftUI
import SwiftVLC

private let readMe = """
Pre-generates a grid of 12 `media.thumbnail(at:)` tiles across the video's \
duration, then snaps the nearest tile into a bubble above the slider thumb on \
scrub. The source is downloaded once into the app's caches directory so every \
thumbnail decode is CPU-bound (~200 ms) instead of network-bound.
"""

private let tileCount = 12

struct ThumbnailScrubCase: View {
  @State private var player = Player()
  @State private var cache = RemoteMediaCache()
  @State private var previewPosition: Double = 0
  @State private var tiles: [Tile] = []
  @State private var isScrubbing = false

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Scrub") {
        scrubSlider
        timeRow("Preview", value: format(previewPosition))
        timeRow("Current", value: format(player.position))
        timeRow("Tiles", value: tilesStatus)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Thumbnail scrubbing")
    .task { await prepare() }
    .onDisappear {
      cache.cancel()
      player.stop()
    }
  }

  // MARK: - Subviews

  @ViewBuilder
  private var scrubSlider: some View {
    #if os(tvOS)
    Text(String(format: "%.2f", previewPosition)).monospacedDigit()
    #else
    VStack(spacing: 0) {
      ScrubBubble(
        isVisible: isScrubbing,
        fraction: previewPosition,
        image: nearestTile()?.image,
        timeLabel: format(previewPosition)
      )
      Slider(
        value: $previewPosition,
        in: 0...1,
        onEditingChanged: { editing in
          withAnimation(.easeOut(duration: 0.12)) { isScrubbing = editing }
          if !editing { player.position = previewPosition }
        }
      )
    }
    #endif
  }

  private func timeRow(_ label: String, value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value).foregroundStyle(.secondary).monospacedDigit()
    }
  }

  // MARK: - State derivations

  /// A single row that reflects the pipeline: caching the source, then
  /// decoding tiles. Avoids a second "Source" row that would only
  /// matter during the brief download window.
  private var tilesStatus: String {
    switch cache.state {
    case .downloading(let received, let total):
      let mb = { (b: Int64) in String(format: "%.0f MB", Double(b) / 1_048_576) }
      return total.map { "Downloading \(mb(received)) / \(mb($0))" } ?? "Downloading \(mb(received))"
    case .failed(let reason):
      return "Failed: \(reason)"
    default:
      return "\(tiles.count) / \(tileCount)"
    }
  }

  // MARK: - Loading pipeline

  /// 1. Materialize the source to a local `file://` URL (download once).
  /// 2. Start playback from the local file.
  /// 3. Generate the tile grid against the same local file.
  private func prepare() async {
    guard let url = try? await cache.materialize(TestMedia.bigBuckBunny) else { return }
    try? player.play(url: url)

    // Tile offsets are relative to duration — wait for it.
    while player.duration == nil, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard let duration = player.duration, !Task.isCancelled else { return }
    guard let media = try? Media(url: url) else { return }

    for index in 0..<tileCount {
      guard !Task.isCancelled else { return }
      let fraction = (Double(index) + 0.5) / Double(tileCount)
      let offset = duration * fraction
      if
        let data = try? await media.thumbnail(
          at: offset, width: 240, height: 135,
          seekMode: .precise, timeout: .seconds(30)
        ),
        let image = PlatformImage(data: data) {
        tiles.append(Tile(id: index, offset: offset, image: image))
        tiles.sort { $0.offset < $1.offset }
      }
    }
  }

  // MARK: - Lookup + formatting

  private func nearestTile() -> Tile? {
    guard !tiles.isEmpty, let duration = player.duration else { return nil }
    let target = duration.seconds * previewPosition
    return tiles.min { abs($0.offset.seconds - target) < abs($1.offset.seconds - target) }
  }

  private func format(_ fraction: Double) -> String {
    guard let duration = player.duration, duration > .zero else { return "--:--" }
    let s = Int((duration * fraction).components.seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
  }
}

// MARK: - Tile model

private struct Tile: Identifiable, Hashable {
  let id: Int
  let offset: Duration
  let image: PlatformImage
}

extension Duration {
  fileprivate var seconds: Double {
    let c = components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
  }
}
