import SwiftUI
import SwiftVLC

private let readMe = """
End-to-end recast on one `Player`: start local playback, optionally \
start PiP, then hand the session to a discovered renderer with \
`recast(to:)` and bring it back with `recast(to: nil)`. The log records \
`currentTime` around every hop (sampled once per second in between), \
each state transition, and any thrown error. This validates harness \
item (d′); item (d) — starting a cast while the PiP window is up — is \
observational on this same screen. On tvOS the bundled libVLC ships no \
renderer output backends, so this screen is meaningful on iOS devices \
only.

Selecting a subtitle track forces the cast pipeline to transcode the \
video and burn the subtitle in (the receiver has no subtitle track of \
its own), so it appears on the TV at the cost of an on-device encode.
"""

struct MatrixScreenD: View {
  let streams: HarnessStreams

  @State private var player = Player()
  @State private var pip: PiPController?
  @State private var services: [RendererService] = []
  @State private var selectedService = ""
  @State private var discoverer: RendererDiscoverer?
  @State private var renderers: [RendererItem] = []
  @State private var log: [LogLine] = []
  @State private var lastTimeLog: Date?

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
  }

  var body: some View {
    @Bindable var bindable = player

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

      Section("Stream") {
        ForEach(streams.configured, id: \.key) { target in
          Button("Load \(target.key.rawValue)") {
            append("load() → \(target.key.rawValue)")
            try? player.play(url: target.url)
          }
        }
      }

      if !player.subtitleTracks.isEmpty {
        Section("Subtitles") {
          Picker("Track", selection: $bindable.selectedSubtitleTrack) {
            Text("Off").tag(Track?.none)
            ForEach(player.subtitleTracks) { track in
              Text(track.name).tag(Track?.some(track))
            }
          }
        }
      }

      discoverySection

      logSection

      ResultRecorderSection(screenID: "matrix-d")
    }
    .showcaseFormStyle()
    .navigationTitle("(d) Cast while PiP")
    .task { loadServices() }
    .task(id: selectedService) { await consumeDiscoveryEvents() }
    .task { await observeEvents() }
    .onChange(of: pip?.isActive) { _, isActive in
      if let isActive {
        append("pip.isActive → \(isActive)")
      }
    }
    .onDisappear {
      discoverer?.stop()
      player.stop()
    }
  }

  private var discoverySection: some View {
    Section("Renderers") {
      if services.isEmpty {
        Text("No renderer discoverers on this platform")
          .foregroundStyle(.secondary)
      } else {
        Picker("Service", selection: $selectedService) {
          ForEach(services, id: \.name) { service in
            Text(service.longName).tag(service.name)
          }
        }
      }

      if renderers.isEmpty {
        Text("Searching…")
          .foregroundStyle(.secondary)
      } else {
        ForEach(renderers) { renderer in
          HStack {
            VStack(alignment: .leading) {
              Text(renderer.name)
              Text(renderer.type)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Recast") {
              recast(to: renderer)
            }
            .buttonStyle(.bordered)
          }
        }
      }

      Button("Back to local") {
        recast(to: nil)
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
      Text("Event log")
    } footer: {
      if !log.isEmpty {
        Button("Clear log") { log.removeAll() }
      }
    }
  }

  private func loadServices() {
    services = RendererDiscoverer.availableServices()
    selectedService = services.first?.name ?? ""
  }

  private func consumeDiscoveryEvents() async {
    guard !selectedService.isEmpty else { return }
    discoverer?.stop()
    renderers = []

    guard let d = try? RendererDiscoverer(name: selectedService) else {
      append("discoverer creation failed: \(selectedService)")
      return
    }
    discoverer = d
    do {
      try d.start()
      append("discovery started: \(selectedService)")
    } catch {
      append("discovery start threw: \(error)")
      return
    }

    for await event in d.events {
      switch event {
      case .itemAdded(let renderer):
        renderers.append(renderer)
        append("renderer found: \(renderer.name) (\(renderer.type))")
      case .itemDeleted(let renderer):
        renderers.removeAll { $0 == renderer }
        append("renderer lost: \(renderer.name)")
      }
    }
  }

  private func recast(to renderer: RendererItem?) {
    let label = renderer.map(\.name) ?? "local"
    append("recast(to: \(label)) at \(player.currentTime.formatted)")
    Task {
      do {
        try await player.recast(to: renderer)
        append("recast → \(label) done, currentTime = \(player.currentTime.formatted)")
      } catch {
        append("recast → \(label) threw: \(error)")
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
