import SwiftUI
import SwiftVLC

private let readMe = """
`player.events(policy:filter:)` returns an independent `AsyncStream<PlayerEvent>` per \
call, so multiple views can observe concurrently. This screen subscribes before \
`play()` with the lossless `.unbounded` policy and a filter that keeps the \
`timeChanged`/`positionChanged`/`bufferingProgress` firehose out of the buffer, so no \
lifecycle event can be dropped however briefly the UI stalls.
"""

struct EventsCase: View {
  @State private var player = Player()
  @State private var log: [LogLine] = []

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
          .accessibilityIdentifier(AccessibilityID.Events.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Events.playPauseButton)
      }

      Section("Events") {
        if log.isEmpty {
          Text("Waiting…").foregroundStyle(.secondary)
        } else {
          ForEach(log) { entry in
            Text(entry.text).font(.caption.monospaced())
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Events")
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
    try? player.play(url: TestMedia.demo)
    for await event in events {
      log.insert(LogLine(text: describe(event)), at: 0)
      if log.count > 50 {
        log.removeLast()
      }
    }
  }

  private func describe(_ event: PlayerEvent) -> String {
    switch event {
    case .stateChanged(let s): "state → \(s)"
    case .lengthChanged(let d): "length → \(Int(d.components.seconds))s"
    case .seekableChanged(let b): "seekable → \(b)"
    case .pausableChanged(let b): "pausable → \(b)"
    case .tracksChanged: "tracks changed"
    case .mediaChanged: "media changed"
    case .volumeChanged(let v): "volume → \(String(format: "%.2f", v))"
    case .muted: "muted"
    case .unmuted: "unmuted"
    case .encounteredError: "error"
    case .snapshotTaken(let path): "snapshot → \(URL(fileURLWithPath: path).lastPathComponent)"
    case .recordingChanged(let rec, _): "recording → \(rec)"
    default: "\(event)"
    }
  }
}
