import SwiftUI
import SwiftVLC
import UIKit

struct TVThumbnailScrubCase: View {
  @State private var player = Player()
  @State private var previewPosition: Double = 0
  @State private var tiles: [Tile] = []
  @State private var isPreparing = false

  private let tileCount = 12

  var body: some View {
    TVShowcaseContent(
      title: "Thumbnail Scrubbing",
      summary: "Generate thumbnail tiles from Media, then use the nearest tile as the scrub preview.",
      usage: "Generate tiles, step through the preview position, and use the image to confirm the nearest thumbnail."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Scrub Preview") {
          if let tile = nearestTile() {
            Image(uiImage: tile.image)
              .resizable()
              .aspectRatio(16 / 9, contentMode: .fit)
              .frame(maxHeight: 150)
              .clipShape(.rect(cornerRadius: 8))
          } else {
            ProgressView("Preparing thumbnails...")
          }

          TVSlider(
            "Preview",
            value: $previewPosition,
            in: 0...1,
            step: 0.05
          ) { _ in previewLabel }
          Text(previewLabel)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    } sidebar: {
      TVSection(title: "Tiles") {
        TVMetricGrid {
          TVMetricRow(title: "Generated", value: "\(tiles.count) / \(tileCount)")
          TVMetricRow(title: "Preparing", value: isPreparing ? "Yes" : "No")
          TVMetricRow(title: "Position", value: String(format: "%.2f", previewPosition))
        }
        Button("Regenerate", systemImage: "arrow.clockwise") { Task { await regenerateButtonTapped() } }
          .disabled(isPreparing)
      }
      TVLibrarySurface(symbols: ["Media.thumbnail(at:)", "player.position"])
    }
    .task { await task() }
    .onChange(of: previewPosition) { player.position = previewPosition }
    .onDisappear { player.stop() }
  }

  private var previewLabel: String {
    guard let duration = player.duration else { return "--:--" }
    return durationLabel(duration * previewPosition)
  }

  private func task() async {
    try? player.play(url: TVTestMedia.demo)
    await generateTiles()
  }

  private func regenerateButtonTapped() async {
    await generateTiles()
  }

  private func generateTiles() async {
    guard !isPreparing else { return }
    isPreparing = true
    tiles = []
    defer { isPreparing = false }

    while player.duration == nil, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard let duration = player.duration, let media = try? Media(url: TVTestMedia.demo) else { return }

    for index in 0..<tileCount {
      guard !Task.isCancelled else { return }
      let fraction = (Double(index) + 0.5) / Double(tileCount)
      if
        let data = try? await media.thumbnail(
          at: duration * fraction,
          width: 240,
          height: 135,
          seekMode: .precise,
          timeout: .seconds(30)
        ),
        let image = UIImage(data: data) {
        tiles.append(Tile(id: index, offset: duration * fraction, image: image))
      }
    }
  }

  private func nearestTile() -> Tile? {
    guard let duration = player.duration else { return nil }
    let target = Double(duration.milliseconds) * previewPosition
    return tiles.min {
      abs(Double($0.offset.milliseconds) - target) < abs(Double($1.offset.milliseconds) - target)
    }
  }
}

private struct Tile: Identifiable {
  let id: Int
  let offset: Duration
  let image: UIImage
}
