import SwiftUI
import SwiftVLC

private let readMe = """
Compares the static `--freetype-fontsize=40` option against the \
runtime `SubtitleScale` API. The dedicated player runs on its own \
`VLCInstance` created with that extra argument; the instance is held \
alongside its player so it outlives it. Flip the control below to play \
the same stream on the shared-instance player and approximate the size \
with `SubtitleScale(approximatePoints: 40)` instead. Record whether \
the static option visibly changes subtitle size on device, and how the \
two renderings compare.
"""

struct MatrixScreenG: View {
  let streams: HarnessStreams

  @State private var dedicatedInstance: VLCInstance?
  @State private var dedicatedPlayer: Player?
  @State private var sharedPlayer = Player()
  @State private var useSharedScale = false
  @State private var approximatePoints = 40.0
  @State private var log: [LogLine] = []

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
  }

  private var activePlayer: Player? {
    useSharedScale ? sharedPlayer : dedicatedPlayer
  }

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        if let activePlayer {
          VideoView(activePlayer)
            .id(useSharedScale)
            .aspectRatio(16 / 9, contentMode: .fit)
            .listRowInsets(EdgeInsets())
        } else {
          Text("Creating dedicated instance…")
            .foregroundStyle(.secondary)
        }
      } footer: {
        if let activePlayer {
          PlayPauseFooter(player: activePlayer)
        }
      }

      Section {
        Toggle("Use SubtitleScale on shared instance", isOn: $useSharedScale)
        LabeledContent(
          "Dedicated instance",
          value: dedicatedInstance == nil ? "not created" : "alive"
        )
        if useSharedScale {
          Stepper(
            "approximatePoints: \(Int(approximatePoints))",
            value: $approximatePoints,
            in: 10...90,
            step: 2
          )
        }
      } footer: {
        Text(
          """
          Off: dedicated VLCInstance with --freetype-fontsize=40. \
          On: shared instance + setSubtitleScale(SubtitleScale(\
          approximatePoints:)).
          """
        )
      }

      Section("Stream") {
        Button("Restart subtitled stream") { activate() }
      }

      subtitleTrackSection

      logSection

      ResultRecorderSection(screenID: "matrix-g")
    }
    .showcaseFormStyle()
    .navigationTitle("(g) freetype-fontsize")
    .task(id: useSharedScale) { activate() }
    .onChange(of: approximatePoints) { _, points in
      guard useSharedScale else { return }
      sharedPlayer.setSubtitleScale(SubtitleScale(approximatePoints: points))
      append("setSubtitleScale(approximatePoints: \(Int(points)))")
    }
    .onDisappear {
      sharedPlayer.stop()
      dedicatedPlayer?.stop()
    }
  }

  private var subtitleTrackSection: some View {
    Section("Subtitle track") {
      if let activePlayer, !activePlayer.subtitleTracks.isEmpty {
        Picker(
          "Track",
          selection: Binding(
            get: { activePlayer.selectedSubtitleTrack },
            set: { activePlayer.selectedSubtitleTrack = $0 }
          )
        ) {
          Text("Off").tag(Track?.none)
          ForEach(activePlayer.subtitleTracks) { track in
            Text(track.name).tag(Track?.some(track))
          }
        }
      } else {
        Text("No subtitle tracks yet")
          .foregroundStyle(.secondary)
      }
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

  private func activate() {
    guard let url = streams.subtitled else { return }

    if useSharedScale {
      dedicatedPlayer?.stop()
      append("shared play() with runtime SubtitleScale")
      try? sharedPlayer.play(url: url)
      sharedPlayer.setSubtitleScale(SubtitleScale(approximatePoints: approximatePoints))
    } else {
      sharedPlayer.stop()
      if dedicatedPlayer == nil {
        do {
          let instance = try VLCInstance(
            arguments: VLCInstance.defaultArguments + ["--freetype-fontsize=40"]
          )
          dedicatedInstance = instance
          dedicatedPlayer = Player(instance: instance)
          append("created dedicated instance with --freetype-fontsize=40")
        } catch {
          append("dedicated instance creation threw: \(error)")
          return
        }
      }
      guard let dedicatedPlayer else { return }
      append("dedicated play() with static --freetype-fontsize=40")
      try? dedicatedPlayer.play(url: url)
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
