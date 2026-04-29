import SwiftUI
import SwiftVLC

struct MacDiscoveryLANCase: View {
  @State private var services: [DiscoveryService] = []
  @State private var selectedService = ""
  @State private var discoverer: MediaDiscoverer?
  @State private var items: [String] = []

  var body: some View {
    MacShowcaseContent(
      title: "LAN Discovery",
      summary: "List LAN media discovery services, start one, and poll its MediaList for discovered URLs.",
      usage: "Start a discovery service and refresh the media list to inspect URLs advertised on the local network."
    ) {
      MacSection(title: "Services") {
        if services.isEmpty {
          MacPlaceholderRow(text: "No LAN discoverers are available on this host.")
        } else {
          Picker("Service", selection: $selectedService) {
            ForEach(services, id: \.name) { service in
              Text(service.longName).tag(service.name)
            }
          }
        }
      }
    } sidebar: {
      MacSection(title: "Discovered") {
        if items.isEmpty {
          MacPlaceholderRow(text: "Nothing discovered yet.")
        } else {
          ForEach(items, id: \.self) { item in
            Text(item)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
      }
      MacLibrarySurface(symbols: ["MediaDiscoverer.availableServices(category:)", "MediaDiscoverer.start()", "discoverer.mediaList"])
    }
    .task { task() }
    .task(id: selectedService) { await selectedServiceTask() }
    .onDisappear { discoverer?.stop() }
  }

  private func task() {
    services = MediaDiscoverer.availableServices(category: .lan)
    selectedService = services.first?.name ?? ""
  }

  private func selectedServiceTask() async {
    guard !selectedService.isEmpty else { return }
    discoverer?.stop()
    discoverer = try? MediaDiscoverer(name: selectedService)
    try? discoverer?.start()
    items = []

    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        break
      }
      refreshDiscoveredItems()
    }
  }

  private func refreshDiscoveredItems() {
    guard let list = discoverer?.mediaList else { return }
    items = list.withLocked { view in
      (0..<view.count).compactMap { view.media(at: $0)?.mrl }
    }
  }
}
