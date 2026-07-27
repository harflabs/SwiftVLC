@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

/// Waits until the native player reports `media` as its *current* media.
///
/// `libvlc_media_player_set_media()` does not always take effect synchronously.
/// When the player already owns an input, the core queues the replacement and
/// only swaps `player->media` once that input has drained
/// (`vlc_player_SetCurrentMedia()`), which is why
/// `libvlc_media_player_get_media()` is documented to keep returning the
/// previous media until the switch is notified by
/// `libvlc_MediaPlayerMediaChanged`.
///
/// Tests that drive `set_media` directly and then synthesise a `.mediaChanged`
/// event must therefore wait for the switch instead of assuming it already
/// happened. On an idle player the wait returns on the first check.
@MainActor
func awaitNativeMediaSwitch(
  on player: Player,
  to media: Media,
  timeout: Duration = .seconds(3),
  sourceLocation: SourceLocation = #_sourceLocation
)
  async throws {
  let expected = media.mrl
  let switched = try await poll(every: .milliseconds(10), timeout: timeout) {
    guard let current = libvlc_media_player_get_media(player.pointer) else {
      return expected == nil
    }
    defer { libvlc_media_release(current) }
    guard let raw = libvlc_media_get_mrl(current) else { return false }
    // libVLC allocates this string; release it through libvlc_free, as
    // Media.mrl does, rather than assuming a shared allocator.
    defer { libvlc_free(raw) }
    return String(cString: raw) == expected
  }
  #expect(
    switched,
    "native player never switched to \(expected ?? "nil")",
    sourceLocation: sourceLocation
  )
}
