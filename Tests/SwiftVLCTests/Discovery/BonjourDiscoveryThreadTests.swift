@testable import SwiftVLC
import dnssd
import Foundation
import Testing

extension Integration {
  /// libVLC's Bonjour discovery is built on `NSNetServiceBrowser`, which
  /// delivers results through the run loop of the thread that created it.
  /// A discoverer started from a task or a dispatch queue therefore used to
  /// start successfully and then never report anything.
  struct BonjourDiscoveryThreadTests {
    /// Local-only because CI runners have no usable mDNS, and because the
    /// test advertises a (host-local) fake Cast device while it runs.
    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `Chromecast discovery started off the main thread reports devices`() async throws {
      let friendlyName = "SwiftVLC Test \(UInt32.random(in: 0...UInt32.max))"
      let advertisement = try HostLocalCastAdvertisement(friendlyName: friendlyName)
      defer { advertisement.stop() }

      let discoverer = try RendererDiscoverer(
        name: "Bonjour_renderer",
        instance: TestInstance.shared
      )
      let events = discoverer.events
      try await Task.detached { try discoverer.start() }.value
      defer { discoverer.stop() }

      let renderer = await Self.firstAddedRenderer(
        in: events,
        within: .seconds(10)
      ) { $0.name.hasPrefix(friendlyName) }

      #expect(renderer?.type == "chromecast")
      #expect(renderer?.canVideo == true)
    }

    @Test(
      arguments: [
        ("Bonjour_renderer", DiscoveryLifecycle.Lane.runLoopThread),
        ("bonjour_renderer", .runLoopThread),
        ("mdns_renderer", .runLoopThread),
        ("Bonjour", .runLoopThread),
        ("mdns{timeout=5}", .runLoopThread),
        ("upnp_renderer", .serialQueue),
        ("upnp", .serialQueue),
        ("sap", .serialQueue),
        ("bonjourish", .serialQueue)
      ]
    )
    func `Only Bonjour-backed services run on the run-loop thread`(
      name: String,
      lane: DiscoveryLifecycle.Lane
    ) {
      #expect(DiscoveryLifecycle.lane(forServiceNamed: name) == lane)
    }

    /// A stop issued from inside a discovery callback is already on the
    /// run-loop thread and must not wait for itself.
    /// The run loop still holds its block for a moment after the block has
    /// signalled the waiting caller. If the block kept the caller's
    /// non-escaping closure alive through that moment, the runtime trapped
    /// with "closure argument was escaped".
    @Test(.timeLimit(.minutes(1)))
    func `Synchronous run-loop lane work never outlives its caller`() async {
      await withTaskGroup(of: Int.self) { group in
        for worker in 0..<8 {
          group.addTask {
            var sum = 0
            for value in 0..<5000 {
              sum &+= DiscoveryLifecycle.sync(on: .runLoopThread) { value &+ worker }
            }
            return sum
          }
        }
        var total = 0
        for await sum in group {
          total &+= sum
        }
        #expect(total == 8 * (0..<5000).reduce(0, +) + 5000 * (0..<8).reduce(0, +))
      }
    }

    @Test
    func `Run-loop lane work can re-enter synchronously`() {
      let value = DiscoveryLifecycle.sync(on: .runLoopThread) {
        DiscoveryLifecycle.sync(on: .runLoopThread) { 42 }
      }
      #expect(value == 42)
    }

    private static func firstAddedRenderer(
      in events: AsyncStream<RendererEvent>,
      within timeout: Duration,
      where matches: @escaping @Sendable (RendererItem) -> Bool
    )
      async -> RendererItem? {
      await withTaskGroup(of: RendererItem?.self) { group in
        group.addTask {
          for await event in events {
            if let renderer = event.itemAdded, matches(renderer) {
              return renderer
            }
          }
          return nil
        }
        group.addTask {
          try? await Task.sleep(for: timeout)
          return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
      }
    }
  }
}

/// A `_googlecast._tcp` registration visible only on this host.
///
/// Registered through `dns_sd` rather than `NetService` so it needs no run
/// loop of its own and never reaches the network: other devices on the LAN
/// do not see a phantom Chromecast while the suite runs.
private final class HostLocalCastAdvertisement: @unchecked Sendable {
  private let service: DNSServiceRef

  init(friendlyName: String) throws {
    var record = TXTRecordRef()
    TXTRecordCreate(&record, 0, nil)
    defer { TXTRecordDeallocate(&record) }
    // `fn` is the friendly name, `md` the model, and `ca` the capability
    // bits libVLC reads (1 = video, 4 = audio).
    for (key, value) in [("fn", friendlyName), ("md", "Chromecast"), ("ca", "5")] {
      let bytes = Array(value.utf8)
      TXTRecordSetValue(&record, key, UInt8(bytes.count), bytes)
    }

    var reference: DNSServiceRef?
    let status = DNSServiceRegister(
      &reference,
      0,
      UInt32(bitPattern: -1), // kDNSServiceInterfaceIndexLocalOnly
      "SwiftVLC-Test-\(UInt32.random(in: 0...UInt32.max))",
      "_googlecast._tcp",
      nil,
      nil,
      UInt16(8009).bigEndian,
      TXTRecordGetLength(&record),
      TXTRecordGetBytesPtr(&record),
      nil,
      nil
    )
    guard status == kDNSServiceErr_NoError, let reference else {
      throw VLCError.operationFailed("Register host-local Cast advertisement (\(status))")
    }
    service = reference
  }

  func stop() {
    DNSServiceRefDeallocate(service)
  }
}
