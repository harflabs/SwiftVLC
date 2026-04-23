@testable import SwiftVLC
import Testing

extension Integration {
  struct RendererDiscovererFinalTests {
    @Test
    func `Init from availableServices creates discoverer`() throws {
      let services = RendererDiscoverer.availableServices()
      guard let service = services.first else { return }
      let discoverer = try RendererDiscoverer(name: service.name)
      _ = discoverer.events
    }

    @Test
    func `Start and stop with real service`() throws {
      let services = RendererDiscoverer.availableServices()
      guard let service = services.first else { return }
      let discoverer = try RendererDiscoverer(name: service.name)
      // start() may fail on some platforms (e.g. iOS simulator without network)
      do {
        try discoverer.start()
        discoverer.stop()
      } catch {
        // Acceptable — exercises the throw path
      }
    }

    @Test
    func `Stop without start is safe`() throws {
      let services = RendererDiscoverer.availableServices()
      guard let service = services.first else { return }
      let discoverer = try RendererDiscoverer(name: service.name)
      discoverer.stop()
    }

    @Test(.tags(.async))
    func `Events stream is valid AsyncStream after init`() throws {
      let services = RendererDiscoverer.availableServices()
      guard let service = services.first else { return }
      let discoverer = try RendererDiscoverer(name: service.name)
      let stream: AsyncStream<RendererEvent> = discoverer.events
      let task = Task { for await _ in stream {
        break
      } }
      task.cancel()
    }

    @Test
    func `Deinit with active discovery cleans up safely`() throws {
      let services = RendererDiscoverer.availableServices()
      guard let service = services.first else { return }
      var discoverer: RendererDiscoverer? = try RendererDiscoverer(name: service.name)
      try? discoverer?.start()
      discoverer = nil
    }

    @Test
    func `Deinit without start cleans up safely`() throws {
      let services = RendererDiscoverer.availableServices()
      guard let service = services.first else { return }
      var discoverer: RendererDiscoverer? = try RendererDiscoverer(name: service.name)
      _ = discoverer?.events
      discoverer = nil
    }

    @Test
    func `availableServices returns stable results across calls`() {
      let first = RendererDiscoverer.availableServices()
      let second = RendererDiscoverer.availableServices()
      #expect(first.count == second.count)
      for (a, b) in zip(first, second) {
        #expect(a.name == b.name)
        #expect(a.longName == b.longName)
      }
    }

    @Test
    func `availableServices iterates all descriptors`() {
      let services = RendererDiscoverer.availableServices()
      for service in services {
        #expect(!service.name.isEmpty)
        #expect(!service.longName.isEmpty)
      }
    }

    @Test
    func `Start stop start cycle works`() throws {
      let services = RendererDiscoverer.availableServices()
      guard let service = services.first else { return }
      let discoverer = try RendererDiscoverer(name: service.name)
      do {
        try discoverer.start()
        discoverer.stop()
        try discoverer.start()
        discoverer.stop()
      } catch {
        // start() may fail on some platforms
      }
    }

    @Test
    func `Multiple discoverers for different services coexist`() {
      let services = RendererDiscoverer.availableServices()
      var discoverers: [RendererDiscoverer] = []
      for service in services.prefix(3) {
        if let d = try? RendererDiscoverer(name: service.name) {
          discoverers.append(d)
        }
      }
      for d in discoverers {
        try? d.start()
      }
      for d in discoverers {
        d.stop()
      }
    }

    @Test(.tags(.async))
    func `Events stream consumed and cancelled after start`() async throws {
      let services = RendererDiscoverer.availableServices()
      guard let service = services.first else { return }
      let discoverer = try RendererDiscoverer(name: service.name)
      guard (try? discoverer.start()) != nil else { return }
      let stream = discoverer.events
      let task = Task { for await _ in stream {
        break
      } }
      try await Task.sleep(for: .milliseconds(200))
      task.cancel()
      await task.value
      discoverer.stop()
    }
  }
}
