@testable import SwiftVLC
import Testing

extension Integration {
  /// Lifecycle calls made in an order libVLC itself does not tolerate.
  ///
  /// `libvlc_media_discoverer_stop` dereferences the discovery module
  /// unconditionally, so reaching it while nothing is running crashes the
  /// process, and a second `libvlc_media_discoverer_start` overwrites (and
  /// leaks) the running module. Every test here must reach the native call
  /// its name describes: they resolve their service with `#require` instead of
  /// returning early when a category happens to be empty in this build.
  struct MediaDiscovererLifecycleTests {
    @Test
    func `Stop before start leaves the discoverer idle`() throws {
      let discoverer = try MediaDiscoverer(
        name: DiscoveryTestService.startable().name,
        instance: TestInstance.shared
      )

      discoverer.stop()

      #expect(discoverer.isRunning == false)
    }

    @Test
    func `Stop twice after start stops once`() throws {
      let discoverer = try MediaDiscoverer(
        name: DiscoveryTestService.startable().name,
        instance: TestInstance.shared
      )
      try discoverer.start()
      #expect(discoverer.isRunning)

      discoverer.stop()
      discoverer.stop()

      #expect(discoverer.isRunning == false)
    }

    @Test
    func `Stop after a failed start leaves the discoverer idle`() throws {
      // libVLC only resolves the module when discovery starts, so an unknown
      // name constructs successfully and then fails to start.
      let discoverer = try MediaDiscoverer(
        name: "swiftvlc_no_such_discovery_module",
        instance: TestInstance.shared
      )
      #expect(throws: VLCError.operationFailed("Start media discovery")) {
        try discoverer.start()
      }
      #expect(discoverer.isRunning == false)

      discoverer.stop()

      #expect(discoverer.isRunning == false)
    }

    @Test
    func `Start while running is rejected and keeps the running module`() throws {
      let discoverer = try MediaDiscoverer(
        name: DiscoveryTestService.startable().name,
        instance: TestInstance.shared
      )
      try discoverer.start()

      #expect(throws: VLCError.invalidState("Media discovery is already running")) {
        try discoverer.start()
      }
      #expect(discoverer.isRunning)

      // One stop must fully retire it: a second native start would have
      // leaked the first module and left it running behind this handle.
      discoverer.stop()
      #expect(discoverer.isRunning == false)
    }

    @Test
    func `A stopped discoverer can start again`() throws {
      let discoverer = try MediaDiscoverer(
        name: DiscoveryTestService.startable().name,
        instance: TestInstance.shared
      )
      try discoverer.start()
      discoverer.stop()

      try discoverer.start()
      #expect(discoverer.isRunning)
      discoverer.stop()
      #expect(discoverer.isRunning == false)
    }

    @Test
    func `Releasing a running discoverer after a rejected start does not crash`() throws {
      var discoverer: MediaDiscoverer? = try MediaDiscoverer(
        name: DiscoveryTestService.startable().name,
        instance: TestInstance.shared
      )
      try discoverer?.start()
      #expect(throws: VLCError.self) { try discoverer?.start() }
      discoverer = nil
    }
  }
}
