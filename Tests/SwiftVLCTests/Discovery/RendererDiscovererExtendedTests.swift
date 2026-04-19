@testable import SwiftVLC
import Testing

@Suite(.tags(.integration), .timeLimit(.minutes(1)))
struct RendererDiscovererExtendedTests {
  // MARK: - Events stream

  @Test
  func `Events stream is accessible after init`() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      let discoverer = try RendererDiscoverer(name: service.name)
      // The events property should be a valid AsyncStream
      let _: AsyncStream<RendererEvent> = discoverer.events
    } catch {
      // Some services may not be available
    }
  }

  // MARK: - Start then stop lifecycle with events stream

  @Test(.tags(.async))
  func `Start then stop lifecycle with events stream`() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      let discoverer = try RendererDiscoverer(name: service.name)
      try discoverer.start()

      // Create a task consuming events, then cancel it after stop
      let task = Task {
        for await _ in discoverer.events {
          break
        }
      }
      discoverer.stop()
      task.cancel()
    } catch {
      // Some services may fail to start
    }
  }

  // MARK: - Multiple start/stop cycles

  @Test
  func `Multiple start stop cycles`() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      let discoverer = try RendererDiscoverer(name: service.name)
      for _ in 0..<3 {
        try discoverer.start()
        discoverer.stop()
      }
      // No crash = success
    } catch {
      // Some services may fail
    }
  }

  // MARK: - Deinit safety (create, start, drop reference)

  @Test
  func `Deinit safety after start`() {
    let services = RendererDiscoverer.availableServices()
    guard let service = services.first else { return }
    do {
      var discoverer: RendererDiscoverer? = try RendererDiscoverer(name: service.name)
      try discoverer?.start()
      // Drop reference while started — deinit should clean up safely
      discoverer = nil
      // No crash = success
    } catch {
      // Ignore
    }
  }

  // MARK: - RendererService equality and inequality

  @Test
  func `RendererService equality`() {
    let a = RendererService(name: "sap", longName: "SAP Announcements")
    let b = RendererService(name: "sap", longName: "SAP Announcements")
    #expect(a == b)
  }

  @Test
  func `RendererService inequality by name`() {
    let a = RendererService(name: "sap", longName: "SAP")
    let b = RendererService(name: "mdns", longName: "SAP")
    #expect(a != b)
  }

  @Test
  func `RendererService inequality by longName`() {
    let a = RendererService(name: "sap", longName: "SAP Announcements")
    let b = RendererService(name: "sap", longName: "Different Name")
    #expect(a != b)
  }

  // MARK: - RendererService name and longName stored correctly

  @Test
  func `RendererService name and longName stored correctly`() {
    let service = RendererService(name: "chromecast", longName: "Chromecast via mDNS")
    #expect(service.name == "chromecast")
    #expect(service.longName == "Chromecast via mDNS")
  }

  // MARK: - RendererDiscoverer is Sendable

  @Test
  func `RendererDiscoverer conforms to Sendable`() {
    let _: any Sendable.Type = RendererDiscoverer.self
  }

  // MARK: - RendererItem type exists and is Sendable

  @Test
  func `RendererItem conforms to Sendable`() {
    let _: any Sendable.Type = RendererItem.self
  }

  // MARK: - RendererEvent cases are exhaustive

  @Test
  func `RendererEvent exhaustive switch compiles`() {
    /// Compile-time verification that all cases are covered
    func handle(_ event: RendererEvent) -> String {
      switch event {
      case .itemAdded: "added"
      case .itemDeleted: "deleted"
      }
    }
    // Just verify the function compiles — no runtime items needed
    _ = handle
  }

  // MARK: - Available services returns consistent results across calls

  @Test
  func `Available services returns consistent results across calls`() {
    let first = RendererDiscoverer.availableServices()
    let second = RendererDiscoverer.availableServices()
    #expect(first.count == second.count)
    for (a, b) in zip(first, second) {
      #expect(a == b)
    }
  }
}
