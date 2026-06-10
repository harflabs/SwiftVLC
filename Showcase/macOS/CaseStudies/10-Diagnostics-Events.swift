import SwiftUI
import SwiftVLC

struct MacEventsCase: View {
  @State private var player = Player()
  @State private var log: [EventLine] = []

  var body: some View {
    MacShowcaseContent(
      title: "Events",
      summary: "Subscribe with player.events(policy:filter:) using the lossless .unbounded policy and a filter that keeps the high-volume playback events out of the buffer.",
      usage: "Play, pause, seek, and stop media to watch the filtered, lossless Player.events stream append recent playback events."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
      }
    } sidebar: {
      MacSection(title: "Recent Events") {
        if log.isEmpty {
          MacPlaceholderRow(text: "Waiting for events...")
        } else {
          ForEach(log) { line in
            Text(line.text)
              .font(.caption.monospaced())
          }
        }
      }
      MacLibrarySurface(symbols: ["player.events(policy:filter:)", "AsyncStream<PlayerEvent>"])
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
    try? player.play(url: MacTestMedia.demo)
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
    case .snapshotTaken(let path): "snapshot: \(URL(fileURLWithPath: path).lastPathComponent)"
    case .recordingChanged(let isRecording, _): "recording: \(isRecording)"
    default: event.description
    }
  }
}

private struct EventLine: Identifiable {
  let id = UUID()
  let text: String
}
