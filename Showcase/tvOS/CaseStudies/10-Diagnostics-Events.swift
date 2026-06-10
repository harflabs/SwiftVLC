import SwiftUI
import SwiftVLC

struct TVEventsCase: View {
  @State private var player = Player()
  @State private var log: [EventLine] = []

  var body: some View {
    TVShowcaseContent(
      title: "Events",
      summary: "Subscribe with player.events(policy:filter:) using the lossless .unbounded policy and a filter that keeps the high-volume playback events out of the buffer.",
      usage: "Play, pause, seek, and stop media to watch the filtered, lossless Player.events stream append recent playback events."
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
      TVLibrarySurface(symbols: ["player.events(policy:filter:)", "AsyncStream<PlayerEvent>"])
    }
    .task { await task() }
    .onDisappear { player.stop() }
  }

  private func task() async {
    let events = player.events(policy: .unbounded, filter: { event in
      switch event {
      case .timeChanged, .positionChanged, .bufferingProgress: false
      default: true
      }
    })
    try? player.play(url: TVTestMedia.demo)
    for await event in events {
      log.insert(EventLine(text: describe(event)), at: 0)
      if log.count > 40 {
        log.removeLast()
      }
    }
  }

  private func describe(_ event: PlayerEvent) -> String {
    switch event {
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
