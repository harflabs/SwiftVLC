import SwiftUI
import SwiftVLC

private let readMe = """
Exercises the `startsAutomaticallyFromInline` knob. The flag is \
captured when the underlying view is built, so the toggle below \
**rebuilds the video view from scratch** (`.id(flag)`) — restart \
playback after flipping it. With the flag **on**: play, background the \
app, and record whether the OS PiP window auto-engages. With the flag \
**off**: repeat and record that video stays inline (no PiP window \
appears).
"""

struct MatrixScreenB: View {
  let streams: HarnessStreams

  @State private var player = Player()
  @State private var pip: PiPController?
  @State private var autoStartsFromInline = true
  @State private var log: [LogLine] = []

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
  }

  private var loadTargets: [(key: HarnessStreams.Key, url: URL)] {
    streams.configured.filter { [.vod, .hlsLive].contains($0.key) }
  }

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        PiPVideoView(
          player,
          controller: $pip,
          startsAutomaticallyFromInline: autoStartsFromInline,
          managesAudioSession: true
        )
        .id(autoStartsFromInline)
        .aspectRatio(16 / 9, contentMode: .fit)
        .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section {
        Toggle("startsAutomaticallyFromInline", isOn: $autoStartsFromInline)
      } footer: {
        Text(
          """
          The knob is init-time only; toggling tears the video view down \
          and reconstructs it with the new flag on the same Player.
          """
        )
      }

      Section("Picture in Picture") {
        if let pip {
          LabeledContent("Possible", value: pip.isPossible ? "yes" : "no")
          LabeledContent("Active", value: pip.isActive ? "yes" : "no")
        } else {
          Text("Preparing…")
            .foregroundStyle(.secondary)
        }
      }

      Section("Stream") {
        ForEach(loadTargets, id: \.key) { target in
          Button("Load \(target.key.rawValue)") {
            append("load() → \(target.key.rawValue)")
            try? player.play(url: target.url)
          }
        }
      }

      logSection

      ResultRecorderSection(screenID: "matrix-b")
    }
    .showcaseFormStyle()
    .navigationTitle("(b) Auto-PiP trigger")
    .task { await observeEvents() }
    .onChange(of: autoStartsFromInline) { _, flag in
      append("rebuilt view, startsAutomaticallyFromInline = \(flag)")
    }
    .onChange(of: pip?.isActive) { _, isActive in
      if let isActive {
        append("pip.isActive → \(isActive), player.state = \(player.state)")
      }
    }
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
