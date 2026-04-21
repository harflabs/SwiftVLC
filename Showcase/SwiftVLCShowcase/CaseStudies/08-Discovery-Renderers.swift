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
  @State private var renderers: [Entry] = []

  private struct Entry: Identifiable {
    let id: String
    let item: RendererItem

    init(_ item: RendererItem) {
      self.item = item
      id = "\(item.name)|\(item.type)"
    }
  }

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
          ForEach(renderers) { entry in
            VStack(alignment: .leading) {
              Text(entry.item.name)
              Text(entry.item.type).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Renderer discovery")
    .task {
      services = RendererDiscoverer.availableServices()
      selectedService = services.first?.name ?? ""
    }
    .task(id: selectedService) {
      guard !selectedService.isEmpty else { return }
      discoverer?.stop()
      renderers = []

      guard let d = try? RendererDiscoverer(name: selectedService) else { return }
      discoverer = d
      try? d.start()

      for await event in d.events {
        switch event {
        case .itemAdded(let renderer):
          renderers.append(Entry(renderer))
        case .itemDeleted(let renderer):
          let deletedId = "\(renderer.name)|\(renderer.type)"
          renderers.removeAll { $0.id == deletedId }
        }
      }
    }
    .onDisappear { discoverer?.stop() }
  }
}
