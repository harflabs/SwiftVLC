import SwiftUI
import SwiftVLC

private let readMe = """
Background audio continuation **without** PiP: the video view is built \
with `startsAutomaticallyFromInline: false`, so backgrounding must not \
spawn a PiP window. Start a stream, background the app, and listen — \
audio should keep playing. The log samples `timeChanged` once per \
second with wall-clock timestamps, so on return you can verify events \
kept firing the whole time the app was backgrounded. Record three \
observations: audio continued or stalled, `timeChanged` continuity, \
and whether video resumes on foreground.
"""

struct MatrixScreenE: View {
  let streams: HarnessStreams

  @State private var player = Player()
  @State private var log: [LogLine] = []
  @State private var lastTimeLog: Date?

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
  }

  private var loadTargets: [(key: HarnessStreams.Key, url: URL)] {
    streams.configured.filter { [.hlsLive, .vod, .audioOnly].contains($0.key) }
  }

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        PiPVideoView(player, startsAutomaticallyFromInline: false)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section {
        ForEach(loadTargets, id: \.key) { target in
          Button("Load \(target.key.rawValue)") {
            append("load() → \(target.key.rawValue)")
            try? player.play(url: target.url)
          }
        }
      } header: {
        Text("Stream")
      } footer: {
        Text(
          """
          The audioOnly variant isolates the audio path: a stream with no \
          video track should behave identically in the background.
          """
        )
      }

      logSection

      ResultRecorderSection(screenID: "matrix-e")
    }
    .showcaseFormStyle()
    .navigationTitle("(e) Background audio")
    .task { await observeEvents() }
    .onDisappear { player.stop() }
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
      Text("Event log")
    } footer: {
      if !log.isEmpty {
        Button("Clear log") { log.removeAll() }
      }
    }
  }

  private func observeEvents() async {
    for await event in player.events {
      switch event {
      case .positionChanged, .bufferingProgress:
        continue
      case .timeChanged(let time):
        let now = Date.now
        if lastTimeLog.map({ now.timeIntervalSince($0) >= 1 }) ?? true {
          lastTimeLog = now
          append("timeChanged → \(time.formatted)")
        }
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
