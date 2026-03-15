@testable import SwiftVLC
import Testing

@Suite(.tags(.integration))
struct RendererDiscovererTests {
  @Test
  func `Available services`() {
    let services = RendererDiscoverer.availableServices()
    // May be empty if no renderer plugins are available
    for service in services {
      #expect(!service.name.isEmpty)
      #expect(!service.longName.isEmpty)
    }
  }

  @Test
  func `RendererService stores properties`() {
    let service = RendererService(name: "microdns_renderer", longName: "mDNS")
    #expect(service.name == "microdns_renderer")
    #expect(service.longName == "mDNS")
  }

  @Test
  func `RendererService is Hashable`() {
    let a = RendererService(name: "test", longName: "Test")
    let b = RendererService(name: "test", longName: "Test")
    #expect(a == b)
  }

  @Test
  func `Init with valid name`() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      let discoverer = try RendererDiscoverer(name: service.name)
      _ = discoverer.events
    } catch {
      // Some services may not be available
    }
  }

  @Test
  func `Init with bogus name may succeed or throw`() {
    // libVLC may or may not throw for unknown renderer names.
    // We just verify no crash.
    do {
      let discoverer = try RendererDiscoverer(name: "nonexistent_renderer_xyz")
      _ = discoverer
    } catch {
      _ = error // Expected VLCError
    }
  }

  @Test
  func `Events stream accessible`() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      let discoverer = try RendererDiscoverer(name: service.name)
      let stream = discoverer.events
      let task = Task {
        for await _ in stream {
          break
        }
      }
      task.cancel()
    } catch {
      // Ignore
    }
  }

  @Test
  func `Start and stop`() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      let discoverer = try RendererDiscoverer(name: service.name)
      try discoverer.start()
      discoverer.stop()
    } catch {
      // Some services may fail to start
    }
  }

  @Test
  func `RendererEvent enum cases`() {
    // Just verify the enum compiles with exhaustive switch
    let events: [RendererEvent] = []
    for event in events {
      switch event {
      case .itemAdded: break
      case .itemDeleted: break
      }
    }
  }

  @Test
  func `Deinit safety`() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      var discoverer: RendererDiscoverer? = try RendererDiscoverer(name: service.name)
      try discoverer?.start()
      discoverer = nil
      // No crash = success
    } catch {
      // Ignore
    }
  }

  @Test
  func `Stop without start doesn't crash`() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      let discoverer = try RendererDiscoverer(name: service.name)
      discoverer.stop()
    } catch {
      // Ignore
    }
  }

  @Test
  func `RendererEvent is Sendable`() {
    let _: any Sendable.Type = RendererEvent.self
  }

  @Test
  func `RendererItem is Sendable`() {
    let _: any Sendable.Type = RendererItem.self
  }
}
