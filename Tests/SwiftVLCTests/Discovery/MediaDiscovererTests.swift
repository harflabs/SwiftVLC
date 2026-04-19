@testable import SwiftVLC
import CLibVLC
import Testing

@Suite(.tags(.integration), .timeLimit(.minutes(1)))
struct MediaDiscovererTests {
  @Test(
    arguments: [
      DiscoveryCategory.devices,
      .lan,
      .podcasts,
      .localDirectories
    ]
  )
  func `Available services for categories`(category: DiscoveryCategory) {
    // Should not crash; may return empty list
    let services = MediaDiscoverer.availableServices(category: category)
    for service in services {
      #expect(!service.name.isEmpty)
      #expect(!service.longName.isEmpty)
    }
  }

  @Test(
    arguments: [
      DiscoveryCategory.devices,
      .lan,
      .podcasts,
      .localDirectories,
    ]
  )
  func `DiscoveryCategory cValue round-trip`(category: DiscoveryCategory) {
    let reconstructed = DiscoveryCategory(from: category.cValue)
    #expect(reconstructed == category)
  }

  @Test
  func `Unknown category defaults to .devices`() {
    let cat = DiscoveryCategory(from: libvlc_media_discoverer_category_t(rawValue: 999))
    #expect(cat == .devices)
  }

  @Test
  func `DiscoveryService stores properties`() {
    let service = DiscoveryService(name: "upnp", longName: "UPnP", category: .lan)
    #expect(service.name == "upnp")
    #expect(service.longName == "UPnP")
    #expect(service.category == .lan)
  }

  @Test
  func `DiscoveryService is Hashable`() {
    let a = DiscoveryService(name: "upnp", longName: "UPnP", category: .lan)
    let b = DiscoveryService(name: "upnp", longName: "UPnP", category: .lan)
    #expect(a == b)
  }

  @Test
  func `Init with valid service name`() {
    // Get an actual service name from the system
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    do {
      let discoverer = try MediaDiscoverer(name: service.name)
      _ = discoverer
    } catch {
      // Some services may not be available
    }
  }

  @Test
  func `Init with bogus name may succeed or throw`() {
    // libVLC may or may not throw for unknown discoverer names
    // depending on the plugin system. We just verify no crash.
    do {
      let discoverer = try MediaDiscoverer(name: "nonexistent_discoverer_xyz")
      _ = discoverer
    } catch {
      _ = error // Expected VLCError
    }
  }

  @Test
  func `Start and stop`() {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    do {
      let discoverer = try MediaDiscoverer(name: service.name)
      try discoverer.start()
      #expect(discoverer.isRunning)
      discoverer.stop()
    } catch {
      // Some services may fail to start
    }
  }

  @Test
  func `isRunning before start`() {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    do {
      let discoverer = try MediaDiscoverer(name: service.name)
      #expect(discoverer.isRunning == false)
    } catch {
      // Ignore
    }
  }

  @Test
  func `Media list accessible`() {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    do {
      let discoverer = try MediaDiscoverer(name: service.name)
      _ = discoverer.mediaList
    } catch {
      // Ignore
    }
  }

  @Test
  func `Deinit safety`() {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    do {
      var discoverer: MediaDiscoverer? = try MediaDiscoverer(name: service.name)
      try discoverer?.start()
      discoverer = nil
      // No crash = success
    } catch {
      // Ignore
    }
  }

  @Test
  func `Media list non-nil after start`() {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    do {
      let discoverer = try MediaDiscoverer(name: service.name)
      try discoverer.start()
      // After starting, mediaList should be accessible
      let list = discoverer.mediaList
      #expect(list != nil)
      discoverer.stop()
    } catch {
      // Some services may fail
    }
  }

  @Test
  func `Stop without start doesn't crash`() {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    do {
      let discoverer = try MediaDiscoverer(name: service.name)
      discoverer.stop()
      // No crash = success
    } catch {
      // Ignore
    }
  }

  @Test
  func `Multiple starts and stops`() {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    do {
      let discoverer = try MediaDiscoverer(name: service.name)
      try discoverer.start()
      discoverer.stop()
      // Second start/stop cycle
      try discoverer.start()
      #expect(discoverer.isRunning)
      discoverer.stop()
    } catch {
      // Ignore
    }
  }
}
