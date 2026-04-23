import SwiftUI
import SwiftVLC

private let readMe = """
`player.events` returns an independent `AsyncStream` on every call, fanned out \
internally by an `EventBridge`. Two consumer tasks each filter the firehose \
down to a different subset; cancelling one doesn't affect the other.
"""

struct MultiConsumerEventsCase: View {
  @State private var player = Player()
  @State private var lifecycleLog: [LogLine] = []
  @State private var trackLog: [LogLine] = []

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
  }

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.MultiConsumer.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.MultiConsumer.playPauseButton)
      }

      Section("Consumer A · lifecycle") {
        if lifecycleLog.isEmpty {
          Text("Waiting…")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.MultiConsumer.lifecycleWaitingLabel)
        } else {
          ForEach(lifecycleLog) { line in
            Text(line.text)
              .font(.caption.monospaced())
              .accessibilityIdentifier(AccessibilityID.MultiConsumer.lifecycleLogEntry)
          }
        }
      }

      Section("Consumer B · tracks + media") {
        if trackLog.isEmpty {
          Text("Waiting…")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.MultiConsumer.trackWaitingLabel)
        } else {
          ForEach(trackLog) { line in
            Text(line.text)
              .font(.caption.monospaced())
              .accessibilityIdentifier(AccessibilityID.MultiConsumer.trackLogEntry)
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Multi-consumer events")
    .task { await consumerA() }
    .task { await consumerB() }
    .onDisappear { player.stop() }
  }

  /// Independent stream #1: only lifecycle transitions.
  private func consumerA() async {
    try? player.play(url: TestMedia.demo)
    for await event in player.events {
      let text: String? = switch event {
      case .stateChanged(let state): "state → \(state)"
      case .seekableChanged(let ok): "seekable → \(ok)"
      case .pausableChanged(let ok): "pausable → \(ok)"
      case .encounteredError: "error"
      default: nil
      }
      if let text {
        lifecycleLog.insert(LogLine(text: text), at: 0)
        if lifecycleLog.count > 25 { lifecycleLog.removeLast() }
      }
    }
  }

  /// Independent stream #2: only media / track events.
  private func consumerB() async {
    for await event in player.events {
      let text: String? = switch event {
      case .mediaChanged: "media changed"
      case .tracksChanged: "tracks changed (\(player.audioTracks.count) audio)"
      case .lengthChanged(let dur): "length → \(Int(dur.components.seconds))s"
      case .voutChanged(let count): "vout → \(count)"
      default: nil
      }
      if let text {
        trackLog.insert(LogLine(text: text), at: 0)
        if trackLog.count > 25 { trackLog.removeLast() }
      }
    }
  }
}
