#if os(iOS) || os(macOS)
@testable import SwiftVLC
import CoreMedia
import Synchronization
import Testing

/// AVKit's time-range query reads the player's native handle out of a locked
/// snapshot and then asks libVLC about it. `Player` clears or republishes that
/// snapshot before releasing a handle, but the release itself runs on another
/// queue, so a pointer that was only copied could be freed mid-query. The
/// query has to take its own reference while the snapshot is still locked, as
/// the native iOS and macOS media controllers do.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPTimeRangeHandleRetentionTests {
    private final class Log: @unchecked Sendable {
      struct Entries {
        var retained: [UInt] = []
        var released: [UInt] = []
        var snapshotWasLockedAtRetain: [Bool] = []
      }

      let entries = Mutex(Entries())
    }

    @Test
    func `The query retains the handle under the snapshot lock and releases it once`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      let proxy = controller.playbackDelegateProxy
      let log = Log()
      let live = PiPPlaybackDelegateProxy.HandleRetention.live
      proxy.handleRetention = .init(
        retain: { [weak controller] pointer in
          // `nil` from the non-blocking attempt means another acquisition —
          // the query's own — holds the lock right now.
          let locked = controller?.callbackSnapshot.withLockIfAvailable { _ in true } == nil
          let address = UInt(bitPattern: pointer)
          log.entries.withLock {
            $0.retained.append(address)
            $0.snapshotWasLockedAtRetain.append(locked)
          }
          live.retain(pointer)
        },
        release: { pointer in
          let address = UInt(bitPattern: pointer)
          log.entries.withLock { $0.released.append(address) }
          live.release(pointer)
        }
      )

      let range = proxy.resolveTimeRangeForPlayback()

      let entries = log.entries.withLock { $0 }
      #expect(range.isValid)
      #expect(entries.retained == [UInt(bitPattern: player.pointer)])
      #expect(entries.released == [UInt(bitPattern: player.pointer)])
      #expect(
        entries.snapshotWasLockedAtRetain == [true],
        "the handle was retained after the snapshot lock was dropped, where a release can already have run"
      )
    }

    @Test
    func `A cleared snapshot is answered without touching any handle`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let proxy = controller.playbackDelegateProxy
      let log = Log()
      proxy.handleRetention = .init(
        retain: { pointer in
          let address = UInt(bitPattern: pointer)
          log.entries.withLock { $0.retained.append(address) }
        },
        release: { pointer in
          let address = UInt(bitPattern: pointer)
          log.entries.withLock { $0.released.append(address) }
        }
      )

      controller.invalidateCallbackSnapshot()
      let range = proxy.resolveTimeRangeForPlayback()

      let entries = log.entries.withLock { $0 }
      #expect(!range.isValid)
      #expect(entries.retained.isEmpty)
      #expect(entries.released.isEmpty)
    }
  }
}
#endif
