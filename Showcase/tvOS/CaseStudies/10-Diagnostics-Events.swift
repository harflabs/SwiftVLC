import SwiftUI
import SwiftVLC

struct TVEventsCase: View {
  @State private var player = Player()
  @State private var log: [EventLine] = []

  var body: some View {
    TVShowcaseContent(
      title: "Events",
      summary: "Consume Player.events as an AsyncStream and filter the high-volume playback events.",
      usage: "Play, pause, seek, and stop media to watch the filtered Player.events stream append recent playback events."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
      }
    } sidebar: {
      TVSection(title: "Recent Events", isFocusable: true) {
        if log.isEmpty {
          TVPlaceholderRow(text: "Waiting for events...")
        } else {
          ForEach(log) { line in
            Text(line.text)
              .font(.caption.monospaced())
          }
        }
      }
      TVLibrarySurface(symbols: ["player.events", "AsyncStream<PlayerEvent>"])
    }
    .task { await task() }
    .onDisappear { player.stop() }
  }

  private func task() async {
    try? player.play(url: TVTestMedia.demo)
    for await event in player.events {
      guard let text = describe(event) else { continue }
      log.insert(EventLine(text: text), at: 0)
      if log.count > 40 {
        log.removeLast()
      }
    }
  }

  private func describe(_ event: PlayerEvent) -> String? {
    switch event {
    case .timeChanged, .positionChanged, .bufferingProgress:
      nil
    case .stateChanged(let state): "state: \(state)"
    case .lengthChanged(let duration): "length: \(durationLabel(duration))"
    case .seekableChanged(let isSeekable): "seekable: \(isSeekable)"
    case .pausableChanged(let isPausable): "pausable: \(isPausable)"
    case .tracksChanged: "tracks changed"
    case .mediaChanged: "media changed"
    case .volumeChanged(let volume): "volume: \(String(format: "%.2f", volume))"
    case .muted: "muted"
    case .unmuted: "unmuted"
    default: event.description
    }
  }
}

private struct EventLine: Identifiable {
  let id = UUID()
  let text: String
}
