import SwiftUI
import SwiftVLC

private let readMe = """
Lenient seek probes against a real timeshift/catch-up stream. \
`seek(toPosition:)` and `jump(by:)` are best-effort and return a \
`Bool` — `true` only means libVLC queued the request; whether \
`set_position` actually lands is a runtime property of the timeshift \
demuxer. The strict `seek(to:)` throws when duration is unknown or the \
stream is not seekable. For each probe, record what the picture and \
the readouts actually do — not just the returned value.
"""

struct MatrixScreenF: View {
  let streams: HarnessStreams

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
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Readouts") {
        LabeledContent("currentTime", value: player.currentTime.formatted)
        LabeledContent("duration", value: player.duration?.formatted ?? "unknown")
        LabeledContent("isSeekable", value: player.isSeekable ? "yes" : "no")
        LabeledContent("position", value: String(format: "%.3f", player.position))
      }

      Section("Lenient seek(toPosition:)") {
        ForEach([0.25, 0.5, 0.9], id: \.self) { fraction in
          Button("seek(toPosition: \(String(format: "%.2f", fraction)))") {
            let accepted = player.seek(toPosition: PlaybackPosition(fraction))
            append("seek(toPosition: \(fraction)) → \(accepted)")
          }
        }
      }

      Section("Lenient jump(by:)") {
        jumpButton("jump(by: −5m)", offset: .seconds(-300))
        jumpButton("jump(by: −30s)", offset: .seconds(-30))
        jumpButton("jump(by: +30s)", offset: .seconds(30))
        jumpButton("jump(by: +5m)", offset: .seconds(300))
      }

      Section("Strict seek(to:)") {
        Button("try seek(to: 0.5)") {
          do {
            try player.seek(to: PlaybackPosition(0.5))
            append("strict seek(to: 0.5) succeeded")
          } catch {
            append("strict seek(to: 0.5) threw: \(error)")
          }
        }
      }

      logSection

      ResultRecorderSection(screenID: "matrix-f")
    }
    .showcaseFormStyle()
    .navigationTitle("(f) Timeshift seek")
    .task {
      if let catchup = streams.catchup {
        append("load() → catchup")
        try? player.play(url: catchup)
      }
      await observeEvents()
    }
    .onDisappear { player.stop() }
  }

  private func jumpButton(_ title: String, offset: Duration) -> some View {
    Button(title) {
      let accepted = player.jump(by: offset)
      append("\(title) → \(accepted)")
    }
  }

  private var logSection: some View {
    Section {
      if log.isEmpty {
        Text("Waiting…")
          .foregroundStyle(.secondary)
      } else {
        ForEach(log) { entry in
          Text(entry.text)
            .font(.caption.monospaced())
        }
      }
    } header: {
      Text("Log")
    } footer: {
      if !log.isEmpty {
        Button("Clear log") { log.removeAll() }
      }
    }
  }

  private func observeEvents() async {
    for await event in player.events {
      switch event {
      case .timeChanged, .positionChanged, .bufferingProgress:
        continue
      case .stateChanged(let state):
        append("state → \(state)")
      default:
        append("\(event)")
      }
    }
  }

  private func append(_ text: String) {
    let timestamp = Date.now.formatted(
      .dateTime.hour().minute().second().secondFraction(.fractional(2))
    )
    log.insert(LogLine(text: "\(timestamp)  \(text)"), at: 0)
    if log.count > 200 {
      log.removeLast()
    }
  }
}
