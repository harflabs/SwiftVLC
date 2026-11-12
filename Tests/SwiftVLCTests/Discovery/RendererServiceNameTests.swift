@testable import SwiftVLC
import Testing

extension Integration {
  /// The casting guide tells apps to select a renderer service by name, so
  /// the names it prints are part of what the bundled libVLC must keep.
  struct RendererServiceNameTests {
    @Test
    func `The bundled libVLC lists the documented renderer services`() {
      let names = RendererDiscoverer
        .availableServices(instance: TestInstance.shared)
        .map(\.name)

      #expect(names.contains("Bonjour_renderer"))
      #expect(names.contains("upnp_renderer"))
    }

    @Test
    func `The documented Chromecast service starts and stops by name`() throws {
      let discoverer = try RendererDiscoverer(
        name: "Bonjour_renderer",
        instance: TestInstance.shared
      )

      try discoverer.start()
      discoverer.stop()
    }
  }
}
