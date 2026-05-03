import SwiftUI
import SwiftVLC

struct MacDiscoveryRenderersCase: View {
  @State private var player = Player()
  @State private var services: [RendererService] = []
  @State private var selectedService = ""
  @State private var discoverer: RendererDiscoverer?
  @State private var renderers: [RendererItem] = []
  @State private var selectedRendererID: RendererItem.ID?

  var body: some View {
    MacShowcaseContent(
      title: "Renderer Discovery",
      summary: "Discover renderer targets such as Chromecast, then assign a RendererItem before playback.",
      usage: "Start discovery, choose a renderer when one appears, and the sample restarts through the selected target."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Renderer") {
          if services.isEmpty {
            MacPlaceholderRow(text: "No renderer discoverers are available on this host.")
          } else {
            Picker("Service", selection: $selectedService) {
              ForEach(services, id: \.name) { service in
                Text(service.longName).tag(service.name)
              }
            }
          }

          Group {
            if renderers.isEmpty {
              Text("No renderers found yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
              List(renderers, selection: $selectedRendererID) { renderer in
                VStack(alignment: .leading, spacing: 2) {
                  Text(renderer.name)
                  Text(renderer.type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .tag(renderer.id)
              }
              .frame(minHeight: 150)
            }
          }
          .onChange(of: selectedRendererID) { selectedRendererChanged() }
        }
      }
    } sidebar: {
      MacSection(title: "Renderers") {
        MacMetricGrid {
          MacMetricRow(title: "Found", value: "\(renderers.count)")
          MacMetricRow(title: "Selected", value: selectedRendererID ?? "--")
          MacMetricRow(title: "State", value: player.state.description)
        }
      }
      MacLibrarySurface(symbols: ["RendererDiscoverer.availableServices()", "RendererDiscoverer.events", "player.setRenderer(_:)"])
    }
    .task { task() }
    .task(id: selectedService) { await selectedServiceTask() }
    .onDisappear { viewDisappeared() }
  }

  private func task() {
    services = RendererDiscoverer.availableServices()
    selectedService = services.first?.name ?? ""
    try? player.play(url: MacTestMedia.demo)
  }

  private func selectedServiceTask() async {
    guard !selectedService.isEmpty else { return }
    discoverer?.stop()
    renderers = []
    selectedRendererID = nil

    guard let discoverer = try? RendererDiscoverer(name: selectedService) else { return }
    self.discoverer = discoverer
    try? discoverer.start()

    for await event in discoverer.events {
      switch event {
      case .itemAdded(let renderer):
        renderers.append(renderer)
      case .itemDeleted(let renderer):
        renderers.removeAll { $0 == renderer }
      }
    }
  }

  private func selectedRendererChanged() {
    guard let renderer = renderers.first(where: { $0.id == selectedRendererID }) else { return }
    player.stop()
    try? player.setRenderer(renderer)
    try? player.play(url: MacTestMedia.demo)
  }

  private func viewDisappeared() {
    discoverer?.stop()
    player.stop()
  }
}
