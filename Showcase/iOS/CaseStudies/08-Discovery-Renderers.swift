import SwiftUI
import SwiftVLC

private let readMe = """
`RendererDiscoverer.availableServices()` lists discoverers; each emits \
`.itemAdded` / `.itemDeleted` events via an `AsyncStream`. Pass a `RendererItem` to \
`player.setRenderer(_:)` to start casting.
"""

struct DiscoveryRenderersCase: View {
  @State private var services: [RendererService] = []
  @State private var selectedService = ""
  @State private var discoverer: RendererDiscoverer?
  @State private var renderers: [RendererItem] = []

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section("Service") {
        if services.isEmpty {
          Text("No renderer discoverers on this platform")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.DiscoveryRenderers.emptyServices)
        } else {
          Picker("Service", selection: $selectedService) {
            ForEach(services, id: \.name) { service in
              Text(service.longName).tag(service.name)
            }
          }
          .accessibilityIdentifier(AccessibilityID.DiscoveryRenderers.servicePicker)
        }
      }

      Section("Renderers") {
        if renderers.isEmpty {
          Text("Searching…").foregroundStyle(.secondary)
        } else {
          ForEach(renderers) { renderer in
            VStack(alignment: .leading) {
              Text(renderer.name)
              Text(renderer.type).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Renderer discovery")
    .task { task() }
    .task(id: selectedService) { await consumeDiscoveryEvents() }
    .onDisappear { discoverer?.stop() }
  }

  private func task() {
    services = RendererDiscoverer.availableServices()
    selectedService = services.first?.name ?? ""
  }

  private func consumeDiscoveryEvents() async {
    guard !selectedService.isEmpty else { return }
    discoverer?.stop()
    renderers = []

    guard let d = try? RendererDiscoverer(name: selectedService) else { return }
    discoverer = d
    try? d.start()

    for await event in d.events {
      switch event {
      case .itemAdded(let renderer):
        renderers.append(renderer)
      case .itemDeleted(let renderer):
        renderers.removeAll { $0 == renderer }
      }
    }
  }
}
