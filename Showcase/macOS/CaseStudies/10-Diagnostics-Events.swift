import SwiftUI
import SwiftVLC

struct MacEventsCase: View {
  @State private var player = Player()
  @State private var log: [EventLine] = []

  var body: some View {
    MacShowcaseContent(
      title: "Events",
      summary: "Consume Player.events as an AsyncStream and filter the high-volume playback events.",
      usage: "Play, pause, seek, and stop media to watch the filtered Player.events stream append recent playback events."
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
      MacLibrarySurface(symbols: ["player.events", "AsyncStream<PlayerEvent>"])
    }
    .task { await task() }
    .onDisappear { player.stop() }
  }

  private func task() async {
    try? player.play(url: MacTestMedia.demo)
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
