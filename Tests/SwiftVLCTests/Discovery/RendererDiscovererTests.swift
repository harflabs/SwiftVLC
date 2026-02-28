@testable import SwiftVLC
import Testing

@Suite("RendererDiscoverer", .tags(.integration))
struct RendererDiscovererTests {
  @Test("Available services")
  func availableServices() {
    let services = RendererDiscoverer.availableServices()
    // May be empty if no renderer plugins are available
    for service in services {
      #expect(!service.name.isEmpty)
      #expect(!service.longName.isEmpty)
    }
  }

  @Test("RendererService stores properties")
  func rendererServiceProperties() {
    let service = RendererService(name: "microdns_renderer", longName: "mDNS")
    #expect(service.name == "microdns_renderer")
    #expect(service.longName == "mDNS")
  }

  @Test("RendererService is Hashable")
  func rendererServiceHashable() {
    let a = RendererService(name: "test", longName: "Test")
    let b = RendererService(name: "test", longName: "Test")
    #expect(a == b)
  }

  @Test("Init with valid name")
  func initValidName() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      let discoverer = try RendererDiscoverer(name: service.name)
      _ = discoverer.events
    } catch {
      // Some services may not be available
    }
  }

  @Test("Init with bogus name may succeed or throw")
  func initWithBogusName() {
    // libVLC may or may not throw for unknown renderer names.
    // We just verify no crash.
    do {
      let discoverer = try RendererDiscoverer(name: "nonexistent_renderer_xyz")
      _ = discoverer
    } catch {
      #expect(error is VLCError)
    }
  }

  @Test("Events stream accessible")
  func eventsStreamAccessible() {
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

  @Test("Start and stop")
  func startAndStop() {
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

  @Test("RendererEvent enum cases")
  func rendererEventEnumCases() {
    // Just verify the enum compiles with exhaustive switch
    let events: [RendererEvent] = []
    for event in events {
      switch event {
      case .itemAdded: break
      case .itemDeleted: break
      }
    }
  }

  @Test("Deinit safety")
  func deinitSafety() {
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

  @Test("Stop without start doesn't crash")
  func stopWithoutStart() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      let discoverer = try RendererDiscoverer(name: service.name)
      discoverer.stop()
    } catch {
      // Ignore
    }
  }

  @Test("RendererEvent is Sendable")
  func rendererEventIsSendable() {
    let _: any Sendable.Type = RendererEvent.self
  }

  @Test("RendererItem is Sendable")
  func rendererItemIsSendable() {
    let _: any Sendable.Type = RendererItem.self
  }
}
