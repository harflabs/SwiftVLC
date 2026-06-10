import SwiftUI
@_spi(ValidationHarness) import SwiftVLC

private let readMe = """
Baseline restore/X behavior with **no** restore hook installed. Start \
PiP, tap the restore button, and record what happens; repeat with the X \
button. Probe the native backend before starting PiP, right after \
starting it, and again after a channel zap — note whether the delegate \
identity changes between probes.
"""

struct MatrixScreenC: View {
  let streams: HarnessStreams

  @State private var player = Player()
  @State private var pip: PiPController?
  @State private var log: [LogLine] = []
  @State private var zapIndex = 0

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
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

      Section("Probes") {
        Button("Probe native backend", action: probe)
        Button("Zap to next stream", action: zap)
          .disabled(streams.configured.count < 2)
      }

      logSection

      ResultRecorderSection(screenID: "matrix-c")
    }
    .showcaseFormStyle()
    .navigationTitle("(c) Restore/X baseline")
    .task {
      if let first = streams.configured.first {
        append("load() → \(first.key.rawValue)")
        try? player.play(url: first.url)
      }
      await observeEvents()
    }
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
      Text("Log")
    } footer: {
      if !log.isEmpty {
        Button("Clear log") { log.removeAll() }
      }
    }
  }

  private func probe() {
    guard let pip else {
      append("probe unavailable: controller not ready")
      return
    }
    guard let snapshot = pip.nativeValidationProbe else {
      append("probe unavailable: no native backend")
      return
    }
    append("windowController = \(snapshot.windowControllerClassName ?? "nil")")
    append("avController present = \(snapshot.hasAVController)")
    append("delegate = \(snapshot.avDelegateClassName ?? "nil")")
    for (selector, responds) in snapshot.delegateResponds.sorted(by: { $0.key < $1.key }) {
      append("\(responds ? "responds" : "missing")  \(selector)")
    }
    append("isPossible = \(snapshot.isPossible), isActive = \(snapshot.isActive)")
  }

  private func zap() {
    let targets = streams.configured
    guard targets.count > 1 else { return }
    zapIndex = (zapIndex + 1) % targets.count
    let target = targets[zapIndex]
    append("load() → \(target.key.rawValue)")
    try? player.play(url: target.url)
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
