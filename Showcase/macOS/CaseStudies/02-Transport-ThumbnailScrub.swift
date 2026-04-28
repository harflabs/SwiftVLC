import AppKit
import SwiftUI
import SwiftVLC

struct MacThumbnailScrubCase: View {
  @State private var player = Player()
  @State private var previewPosition: Double = 0
  @State private var tiles: [Tile] = []
  @State private var isPreparing = false

  private let tileCount = 12

  var body: some View {
    MacShowcaseContent(
      title: "Thumbnail Scrubbing",
      summary: "Generate thumbnail tiles from Media, then use the nearest tile as the scrub preview.",
      usage: "Generate tiles, move the scrubber, and use the preview image to confirm the nearest thumbnail for the current position."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Scrub Preview") {
          if let tile = nearestTile() {
            Image(nsImage: tile.image)
              .resizable()
              .aspectRatio(16 / 9, contentMode: .fit)
              .frame(maxHeight: 150)
              .clipShape(.rect(cornerRadius: 8))
          } else {
            ProgressView("Preparing thumbnails...")
          }

          Slider(value: $previewPosition, in: 0...1, onEditingChanged: scrubEditingChanged)
          Text(previewLabel)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    } sidebar: {
      MacSection(title: "Tiles") {
        MacMetricGrid {
          MacMetricRow(title: "Generated", value: "\(tiles.count) / \(tileCount)")
          MacMetricRow(title: "Preparing", value: isPreparing ? "Yes" : "No")
          MacMetricRow(title: "Position", value: String(format: "%.2f", previewPosition))
        }
        Button("Regenerate", systemImage: "arrow.clockwise") { Task { await regenerateButtonTapped() } }
          .disabled(isPreparing)
      }
      MacLibrarySurface(symbols: ["Media.thumbnail(at:)", "player.position"])
    }
    .task { await task() }
    .onDisappear { player.stop() }
  }

  private var previewLabel: String {
    guard let duration = player.duration else { return "--:--" }
    return durationLabel(duration * previewPosition)
  }

  private func task() async {
    try? player.play(url: MacTestMedia.demo)
    await generateTiles()
  }

  private func regenerateButtonTapped() async {
    await generateTiles()
  }

  private func scrubEditingChanged(_ editing: Bool) {
    guard !editing else { return }
    player.position = previewPosition
  }

  private func generateTiles() async {
    guard !isPreparing else { return }
    isPreparing = true
    tiles = []
    defer { isPreparing = false }

    while player.duration == nil, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard let duration = player.duration, let media = try? Media(url: MacTestMedia.demo) else { return }

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
        let image = NSImage(data: data) {
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
  let image: NSImage
}
