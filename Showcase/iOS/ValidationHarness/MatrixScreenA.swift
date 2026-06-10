import SwiftUI
import SwiftVLC

private let readMe = """
Tap a channel button to start playback, then start PiP from the button \
below or by backgrounding the app. While the OS PiP window is up, zap \
between channels — every button issues a `load()` on the **same** \
`Player`. For each transition class (VOD→live, live→live, live→VOD) \
record whether the PiP window survives the zap and how long the picture \
gap or freeze lasts.
"""

struct MatrixScreenA: View {
  let streams: HarnessStreams

  @State private var player = Player()
  @State private var pip: PiPController?
  @State private var log: [LogLine] = []

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
  }

  private var zapTargets: [(key: HarnessStreams.Key, url: URL)] {
    streams.configured.filter { [.liveTS, .hlsLive, .vod].contains($0.key) }
  }

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        PiPVideoView(player, controller: $pip)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Picture in Picture") {
        if let pip {
          LabeledContent("Possible", value: pip.isPossible ? "yes" : "no")
          LabeledContent("Active", value: pip.isActive ? "yes" : "no")
          Button(
            pip.isActive ? "Stop PiP" : "Start PiP",
            systemImage: "pip",
            action: pip.toggle
          )
          .disabled(!pip.isPossible)
        } else {
          Text("Preparing…")
            .foregroundStyle(.secondary)
        }
      }

      Section("Channel zap") {
        ForEach(zapTargets, id: \.key) { target in
          Button("Load \(target.key.rawValue)") {
            append("load() → \(target.key.rawValue)")
            try? player.play(url: target.url)
          }
        }
      }

      logSection

      ResultRecorderSection(screenID: "matrix-a")
    }
    .showcaseFormStyle()
    .navigationTitle("(a) PiP survival")
    .task { await observeEvents() }
    .onChange(of: pip?.isActive) { _, isActive in
      if let isActive {
        append("pip.isActive → \(isActive)")
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
