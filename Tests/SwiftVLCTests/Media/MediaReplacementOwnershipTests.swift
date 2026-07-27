@testable import SwiftVLC
import Foundation
import Testing

/// Swift-side ownership guarantees for rapid media replacement.
///
/// The engine-level regression for this lives in libVLC itself
/// (`test/libvlc/media_switch_ownership.c`, added by
/// `scripts/patches/0007-rapid-set-media-ownership.patch`), where an
/// AddressSanitizer run drives 10,000 active replacements. That test proves the
/// C ownership model is sound; these tests prove SwiftVLC's wrappers sit on top
/// of it correctly.
///
/// Two properties matter here:
///
/// 1. Replacing the media of a *playing* player must not strand the outgoing
///    `Media`. Before the backported fix, libVLC freed the `libvlc_media_t`
///    inside `libvlc_media_player_set_media()` while the outgoing input was
///    still draining and still publishing that media to listeners. SwiftVLC
///    never dereferences the media carried on those events (`EventBridge` maps
///    `libvlc_MediaPlayerMediaChanged` to a payload-free `.mediaChanged`), so it
///    was not directly exposed — but it does keep its own `Media` wrapper alive
///    across the switch, and that wrapper's release must stay balanced.
///
/// 2. `Media` deinit must run once the player has moved on. `Media` owns one
///    libVLC reference and releases it in deinit; under the new model that
///    release forwards to the underlying input item's reference count, so an
///    unbalanced Swift wrapper would either leak the item or over-release it.
extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(2)), .serialized)
  @MainActor struct MediaReplacementOwnershipTests {
    /// Rapid A/B/A replacement on a *started* player. The Swift `Media` is
    /// transferred into the player and dropped by the caller immediately, so
    /// the player's own reference is the only thing keeping it alive while the
    /// outgoing input drains.
    @Test
    func `Rapid media replacement on a playing player stays sound`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let urls = [TestMedia.silenceURL, TestMedia.twosecURL, TestMedia.testMP4URL]

      for index in 0..<30 {
        let media = try Media(url: urls[index % urls.count])
        if index == 0 {
          try player.play(media)
        } else {
          player.load(media)
        }
        // No settling wait: overlapping the outgoing input's teardown with the
        // next load is exactly the condition under test.
        await yieldScheduler(times: 2)
      }

      #expect(player.currentMedia != nil)
      player.stop()
      await yieldScheduler(times: 8)
    }

    /// The outgoing `Media` must deallocate once the player replaces it. A
    /// wrapper that stayed alive would mean SwiftVLC is holding a libVLC
    /// reference it never releases, which under the shared input-item
    /// refcount now also pins the input item.
    @Test
    func `Replaced media deallocates once the player moves on`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())

      weak var weakFirst: Media?
      do {
        let first = try Media(url: TestMedia.silenceURL)
        weakFirst = first
        player.load(first)
      }
      #expect(weakFirst != nil, "player must hold the media it was given")

      // Replace it. The player drops its reference to the first media, which
      // was the last one, so the Swift wrapper must deinit.
      do {
        let second = try Media(url: TestMedia.twosecURL)
        player.load(second)
      }
      await yieldScheduler(times: 8)

      #expect(weakFirst == nil, "replaced Media leaked: player kept its reference after set_media")

      player.stop()
      await yieldScheduler(times: 8)
    }

    /// Dropping the player must release the media it currently holds.
    @Test
    func `Releasing the player releases its current media`() async throws {
      weak var weakMedia: Media?
      do {
        let player = Player(instance: TestInstance.makeAudioOnly())
        let media = try Media(url: TestMedia.silenceURL)
        weakMedia = media
        player.load(media)
        #expect(weakMedia != nil)
      }
      await yieldScheduler(times: 8)

      #expect(weakMedia == nil, "Media outlived its player")
    }

    /// Yields the task scheduler `n` times so pending main-actor work (deinit
    /// cleanup, event-consumer cancellation, observation graph teardown) runs
    /// before we probe a weak reference.
    private func yieldScheduler(times n: Int) async {
      for _ in 0..<n {
        await Task.yield()
      }
    }
  }
}
