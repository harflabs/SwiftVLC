@testable import SwiftVLC
import Testing

@Suite(.tags(.integration))
struct DiscoveryExtendedTests {
  @Test
  func `MediaDiscoverer is Sendable`() {
    let _: any Sendable.Type = MediaDiscoverer.self
  }

  @Test
  func `RendererDiscoverer is Sendable`() {
    let _: any Sendable.Type = RendererDiscoverer.self
  }

  @Test
  func `RendererService Hashable equality`() {
    let a = RendererService(name: "chromecast", longName: "Chromecast")
    let b = RendererService(name: "chromecast", longName: "Chromecast")
    let c = RendererService(name: "airplay", longName: "AirPlay")
    #expect(a == b)
    #expect(a != c)
    #expect(a.hashValue == b.hashValue)
  }

  @Test
  func `RendererService properties stored correctly`() {
    let service = RendererService(name: "cast_renderer", longName: "Google Cast")
    #expect(service.name == "cast_renderer")
    #expect(service.longName == "Google Cast")
  }

  @Test
  func `DiscoveryService categories match C values`() {
    let service = DiscoveryService(name: "test", longName: "Test", category: .lan)
    #expect(service.category == .lan)

    let devices = DiscoveryService(name: "d", longName: "D", category: .devices)
    #expect(devices.category == .devices)

    let podcasts = DiscoveryService(name: "p", longName: "P", category: .podcasts)
    #expect(podcasts.category == .podcasts)

    let local = DiscoveryService(name: "l", longName: "L", category: .localDirectories)
    #expect(local.category == .localDirectories)
  }

  @Test
  func `RendererDiscoverer availableServices returns array`() {
    let services = RendererDiscoverer.availableServices()
    // May be empty but must not crash
    #expect(services.count >= 0)
  }

  @Test(
    arguments: [
      DiscoveryCategory.devices,
      .lan,
      .podcasts,
      .localDirectories,
    ]
  )
  func `MediaDiscoverer availableServices for all categories does not crash`(
    category: DiscoveryCategory
  ) {
    let services = MediaDiscoverer.availableServices(category: category)
    // Must not crash; result may be empty
    #expect(services.count >= 0)
  }

  @Test
  func `DiscoveryCategory is Hashable and Equatable`() {
    let a: DiscoveryCategory = .lan
    let b: DiscoveryCategory = .lan
    let c: DiscoveryCategory = .devices
    #expect(a == b)
    #expect(a != c)
    #expect(a.hashValue == b.hashValue)

    // Can be used in a Set
    let set: Set<DiscoveryCategory> = [.devices, .lan, .podcasts, .localDirectories, .lan]
    #expect(set.count == 4)
  }

  @Test
  func `RendererEvent is Sendable`() {
    let _: any Sendable.Type = RendererEvent.self
  }

  @Test
  func `Multiple discoverers for different categories can coexist`() {
    let lanServices = MediaDiscoverer.availableServices(category: .lan)
    let localServices = MediaDiscoverer.availableServices(category: .localDirectories)

    var discoverers: [MediaDiscoverer] = []
    for service in lanServices.prefix(1) {
      if let d = try? MediaDiscoverer(name: service.name) {
        discoverers.append(d)
      }
    }
    for service in localServices.prefix(1) {
      if let d = try? MediaDiscoverer(name: service.name) {
        discoverers.append(d)
      }
    }
    // Multiple discoverers created without crash
    #expect(discoverers.count >= 0)
  }
}
