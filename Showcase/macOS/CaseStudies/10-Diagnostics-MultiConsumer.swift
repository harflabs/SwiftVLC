import SwiftUI
import SwiftVLC

struct MacMultiConsumerEventsCase: View {
  @State private var player = Player()
  @State private var lifecycleLog: [ConsumerLine] = []
  @State private var trackLog: [ConsumerLine] = []

  var body: some View {
    MacShowcaseContent(
      title: "Multi-consumer Events",
      summary: "Create two independent event streams from the same Player and filter each for a different UI panel.",
      usage: "Play or change tracks to feed two independent Player.events consumers and compare their filtered logs."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        HStack(alignment: .top, spacing: 16) {
          logSection(title: "Lifecycle", lines: lifecycleLog)
          logSection(title: "Tracks + Media", lines: trackLog)
        }
      }
    } sidebar: {
      MacSection(title: "Consumers") {
        MacMetricGrid {
          MacMetricRow(title: "Lifecycle", value: "\(lifecycleLog.count)")
          MacMetricRow(title: "Tracks", value: "\(trackLog.count)")
          MacMetricRow(title: "State", value: player.state.description)
        }
      }
      MacLibrarySurface(symbols: ["player.events", "EventBridge", "AsyncStream"])
    }
    .task { await consumerATask() }
    .task { await consumerBTask() }
    .onDisappear { player.stop() }
  }

  private func logSection(title: String, lines: [ConsumerLine]) -> some View {
    MacSection(title: title) {
      if lines.isEmpty {
        MacPlaceholderRow(text: "Waiting...")
      } else {
        ForEach(lines) { line in
          Text(line.text)
            .font(.caption.monospaced())
        }
      }
    }
  }

  private func consumerATask() async {
    try? player.play(url: MacTestMedia.demo)
    for await event in player.events {
      guard let text = lifecycleDescription(for: event) else { continue }
      lifecycleLog.insert(ConsumerLine(text: text), at: 0)
      if lifecycleLog.count > 20 {
        lifecycleLog.removeLast()
      }
    }
  }

  private func consumerBTask() async {
    for await event in player.events {
      guard let text = trackDescription(for: event) else { continue }
      trackLog.insert(ConsumerLine(text: text), at: 0)
      if trackLog.count > 20 {
        trackLog.removeLast()
      }
    }
  }

  private func lifecycleDescription(for event: PlayerEvent) -> String? {
    switch event {
    case .stateChanged(let state): "state: \(state)"
    case .seekableChanged(let isSeekable): "seekable: \(isSeekable)"
    case .pausableChanged(let isPausable): "pausable: \(isPausable)"
    case .encounteredError: "error"
    default: nil
    }
  }

  private func trackDescription(for event: PlayerEvent) -> String? {
    switch event {
    case .mediaChanged: "media changed"
    case .tracksChanged: "tracks changed (\(player.audioTracks.count) audio)"
    case .lengthChanged(let duration): "length: \(durationLabel(duration))"
    case .voutChanged(let count): "vout: \(count)"
    default: nil
    }
  }
}

private struct ConsumerLine: Identifiable {
  let id = UUID()
  let text: String
}
