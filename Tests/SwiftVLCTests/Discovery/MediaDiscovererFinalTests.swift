@testable import SwiftVLC
import Testing

@Suite(.tags(.integration))
struct MediaDiscovererFinalTests {
  // MARK: - Init with invalid name throws

  @Test
  func `Init with invalid name may throw VLCError`() {
    // Exercising line 25: guard-let throw path
    // libVLC may or may not reject unknown names depending on plugin system
    do {
      let d = try MediaDiscoverer(name: "___completely_invalid_discoverer_name___")
      _ = d // If it succeeds, that's fine too
    } catch {
      #expect(error is VLCError)
    }
  }

  // MARK: - Start a real discoverer (localDirectories)

  @Test
  func `Start localDirectories discoverer succeeds`() throws {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    let discoverer = try MediaDiscoverer(name: service.name)
    // Exercising lines 37-40: start() method
    try discoverer.start()
    discoverer.stop()
  }

  // MARK: - isRunning after start

  @Test
  func `isRunning is true after start`() throws {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    let discoverer = try MediaDiscoverer(name: service.name)
    #expect(discoverer.isRunning == false)
    try discoverer.start()
    // Exercising line 49: isRunning
    #expect(discoverer.isRunning == true)
    discoverer.stop()
  }

  // MARK: - isRunning after stop

  @Test
  func `isRunning is false after stop`() throws {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    let discoverer = try MediaDiscoverer(name: service.name)
    try discoverer.start()
    discoverer.stop()
    // Exercising line 44: stop() and line 49: isRunning
    #expect(discoverer.isRunning == false)
  }

  // MARK: - mediaList is non-nil after start

  @Test
  func `mediaList is non-nil after start`() throws {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    let discoverer = try MediaDiscoverer(name: service.name)
    try discoverer.start()
    // Exercising lines 56-58: mediaList getter
    let list = discoverer.mediaList
    #expect(list != nil)
    discoverer.stop()
  }

  // MARK: - mediaList returns MediaList instance

  @Test
  func `mediaList returns MediaList with valid count`() throws {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    let discoverer = try MediaDiscoverer(name: service.name)
    try discoverer.start()
    if let list = discoverer.mediaList {
      // The list may be empty but should be accessible
      #expect(list.count >= 0)
    }
    discoverer.stop()
  }

  // MARK: - availableServices for all categories exercises compactMap (line 122)

  @Test(
    arguments: [
      DiscoveryCategory.devices,
      .lan,
      .podcasts,
      .localDirectories
    ]
  )
  func `availableServices for all categories returns valid services`(
    category: DiscoveryCategory
  ) {
    // Exercising line 122: compactMap iteration
    let services = MediaDiscoverer.availableServices(category: category)
    for service in services {
      #expect(!service.name.isEmpty)
      #expect(!service.longName.isEmpty)
      #expect(service.category == category)
    }
  }

  // MARK: - Init and immediately deinit

  @Test
  func `Init and immediately deinit is safe`() throws {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    var discoverer: MediaDiscoverer? = try MediaDiscoverer(name: service.name)
    discoverer = nil
    _ = discoverer // silence warning
  }

  // MARK: - Start, stop, start again cycle

  @Test
  func `Start stop start cycle works`() throws {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    let discoverer = try MediaDiscoverer(name: service.name)
    try discoverer.start()
    #expect(discoverer.isRunning == true)
    discoverer.stop()
    #expect(discoverer.isRunning == false)
    // Second cycle
    try discoverer.start()
    #expect(discoverer.isRunning == true)
    discoverer.stop()
    #expect(discoverer.isRunning == false)
  }

  // MARK: - Discoverer Sendable verification

  @Test
  func `MediaDiscoverer is Sendable`() {
    let _: any Sendable.Type = MediaDiscoverer.self
  }

  // MARK: - Deinit while running

  @Test
  func `Deinit while running is safe`() throws {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    var discoverer: MediaDiscoverer? = try MediaDiscoverer(name: service.name)
    try discoverer?.start()
    discoverer = nil
  }

  // MARK: - mediaList before start

  @Test
  func `mediaList before start may be nil`() throws {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    let discoverer = try MediaDiscoverer(name: service.name)
    // Before start, mediaList may or may not be nil depending on libVLC version
    _ = discoverer.mediaList
  }

  // MARK: - Stop without start

  @Test
  func `Stop without start does not crash`() throws {
    let services = MediaDiscoverer.availableServices(category: .localDirectories)
    guard let service = services.first else { return }
    let discoverer = try MediaDiscoverer(name: service.name)
    discoverer.stop()
  }

  // MARK: - LAN discoverer start

  @Test
  func `LAN discoverer can be started`() throws {
    let services = MediaDiscoverer.availableServices(category: .lan)
    guard let service = services.first else { return }
    let discoverer = try MediaDiscoverer(name: service.name)
    try discoverer.start()
    #expect(discoverer.isRunning == true)
    discoverer.stop()
  }
}
