@testable import SwiftVLC
import CLibVLC
import Testing

@Suite("MediaDiscoverer", .tags(.integration), .serialized)
struct MediaDiscovererTests {
  @Test(
    "Available services for categories",
    arguments: [
      DiscoveryCategory.devices,
      .lan,
      .podcasts,
      .localDirectories
    ]
  )
  func availableServicesForCategories(category: DiscoveryCategory) {
    // Should not crash; may return empty list
    let services = MediaDiscoverer.availableServices(category: category)
    for service in services {
      #expect(!service.name.isEmpty)
      #expect(!service.longName.isEmpty)
    }
  }

  @Test(
    "DiscoveryCategory cValue round-trip",
    arguments: [
      DiscoveryCategory.devices,
      .lan,
      .podcasts,
      .localDirectories,
    ]
  )
  func categoryCValueRoundTrip(category: DiscoveryCategory) {
    let reconstructed = DiscoveryCategory(from: category.cValue)
    #expect(reconstructed == category)
  }

  @Test("Unknown category defaults to .devices")
  func unknownCategoryDefaultsToDevices() {
    let cat = DiscoveryCategory(from: libvlc_media_discoverer_category_t(rawValue: 999))
    #expect(cat == .devices)
  }

  @Test("DiscoveryService stores properties")
  func discoveryServiceProperties() {
    let service = DiscoveryService(name: "upnp", longName: "UPnP", category: .lan)
    #expect(service.name == "upnp")
    #expect(service.longName == "UPnP")
    #expect(service.category == .lan)
  }

  @Test("DiscoveryService is Hashable")
  func discoveryServiceHashable() {
    let a = DiscoveryService(name: "upnp", longName: "UPnP", category: .lan)
    let b = DiscoveryService(name: "upnp", longName: "UPnP", category: .lan)
    #expect(a == b)
  }

  @Test("Init with valid service name")
  func initValidName() {
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

  @Test("Init with bogus name may succeed or throw")
  func initWithBogusName() {
    // libVLC may or may not throw for unknown discoverer names
    // depending on the plugin system. We just verify no crash.
    do {
      let discoverer = try MediaDiscoverer(name: "nonexistent_discoverer_xyz")
      _ = discoverer
    } catch {
      #expect(error is VLCError)
    }
  }

  @Test("Start and stop")
  func startAndStop() {
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

  @Test("isRunning before start")
  func isRunningBeforeStart() {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    do {
      let discoverer = try MediaDiscoverer(name: service.name)
      #expect(discoverer.isRunning == false)
    } catch {
      // Ignore
    }
  }

  @Test("Media list accessible")
  func mediaListAccessible() {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    do {
      let discoverer = try MediaDiscoverer(name: service.name)
      _ = discoverer.mediaList
    } catch {
      // Ignore
    }
  }

  @Test("Deinit safety")
  func deinitSafety() {
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

  @Test("Media list non-nil after start")
  func mediaListNonNilAfterStart() {
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

  @Test("Stop without start doesn't crash")
  func stopWithoutStart() {
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

  @Test("Multiple starts and stops")
  func multipleStartsAndStops() {
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
