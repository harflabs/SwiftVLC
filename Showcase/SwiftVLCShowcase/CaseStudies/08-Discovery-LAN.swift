import SwiftUI
import SwiftVLC

private let readMe = """
`MediaDiscoverer.availableServices(category: .lan)` lists network discoverers \
(UPnP, SMB, SAP). Construct one by name, `start()` it, then poll `mediaList` as \
items appear.
"""

struct DiscoveryLANCase: View {
  @State private var services: [DiscoveryService] = []
  @State private var selectedService: String = ""
  @State private var discoverer: MediaDiscoverer?
  @State private var items: [String] = []

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section("Service") {
        if services.isEmpty {
          Text("No LAN discoverers on this platform")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.DiscoveryLAN.emptyServices)
        } else {
          Picker("Service", selection: $selectedService) {
            ForEach(services, id: \.name) { service in
              Text(service.longName).tag(service.name)
            }
          }
          .accessibilityIdentifier(AccessibilityID.DiscoveryLAN.servicePicker)
        }
      }

      Section("Discovered") {
        if items.isEmpty {
          Text("Nothing yet")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.DiscoveryLAN.emptyDiscovered)
        } else {
          ForEach(items, id: \.self) { item in
            Text(item).font(.caption.monospaced())
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("LAN discovery")
    .task {
      services = MediaDiscoverer.availableServices(category: .lan)
      selectedService = services.first?.name ?? ""
    }
    .task(id: selectedService) {
      guard !selectedService.isEmpty else { return }
      discoverer?.stop()
      discoverer = try? MediaDiscoverer(name: selectedService)
      try? discoverer?.start()
      items = []

      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        refresh()
      }
    }
    .onDisappear { discoverer?.stop() }
  }

  private func refresh() {
    guard let list = discoverer?.mediaList else { return }
    items = list.withLocked { view in
      (0..<view.count).compactMap { view.media(at: $0)?.mrl }
    }
  }
}
