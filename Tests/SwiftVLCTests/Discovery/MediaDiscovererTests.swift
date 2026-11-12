@testable import SwiftVLC
import CLibVLC
import Testing

extension Integration {
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
    func `Init with valid service name`() throws {
      let service = try DiscoveryTestService.startable()
      _ = try MediaDiscoverer(name: service.name)
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
    func `Init with empty name may throw VLCError`() {
      do {
        let discoverer = try MediaDiscoverer(name: "")
        _ = discoverer
      } catch {
        guard case .instanceCreationFailed = error else {
          Issue.record("Expected .instanceCreationFailed, got \(error)")
          return
        }
      }
    }

    @Test
    func `Start and stop`() throws {
      let service = try DiscoveryTestService.startable()
      let discoverer = try MediaDiscoverer(name: service.name)
      try discoverer.start()
      #expect(discoverer.isRunning)
      discoverer.stop()
      #expect(discoverer.isRunning == false)
    }

    @Test
    func `isRunning before start`() throws {
      let service = try DiscoveryTestService.startable()
      let discoverer = try MediaDiscoverer(name: service.name)
      #expect(discoverer.isRunning == false)
    }

    @Test
    func `Media list accessible`() throws {
      let service = try DiscoveryTestService.startable()
      let discoverer = try MediaDiscoverer(name: service.name)
      #expect(discoverer.mediaList != nil)
    }

    @Test
    func `Media list adapter adopts a caller-owned reference`() throws {
      let pointer = try #require(libvlc_media_list_new())
      let list = try #require(MediaDiscoverer.adoptMediaList(pointer))

      #expect(list.pointer == pointer)
      #expect(list.isEmpty)
      #expect(MediaDiscoverer.adoptMediaList(nil) == nil)
    }

    @Test
    func `Bundled SAP discoverer exposes its media list`() throws {
      let discoverer = try MediaDiscoverer(name: "sap", instance: TestInstance.shared)

      #expect(discoverer.mediaList != nil)
    }

    @Test
    func `Deinit safety`() throws {
      let service = try DiscoveryTestService.startable()
      var discoverer: MediaDiscoverer? = try MediaDiscoverer(name: service.name)
      try discoverer?.start()
      discoverer = nil
    }

    @Test
    func `Media list non-nil after start`() throws {
      let service = try DiscoveryTestService.startable()
      let discoverer = try MediaDiscoverer(name: service.name)
      try discoverer.start()
      #expect(discoverer.mediaList != nil)
      discoverer.stop()
    }

    @Test
    func `Stop without start doesn't crash`() throws {
      let service = try DiscoveryTestService.startable()
      let discoverer = try MediaDiscoverer(name: service.name)
      discoverer.stop()
      #expect(discoverer.isRunning == false)
    }

    @Test
    func `Multiple starts and stops`() throws {
      let service = try DiscoveryTestService.startable()
      let discoverer = try MediaDiscoverer(name: service.name)
      try discoverer.start()
      discoverer.stop()
      // Second start/stop cycle
      try discoverer.start()
      #expect(discoverer.isRunning)
      discoverer.stop()
    }
  }
}
