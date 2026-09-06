@testable import SwiftVLC
import CLibVLC
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Integration {
  @Suite(.tags(.mainActor), .timeLimit(.minutes(1)))
  @MainActor struct VideoSurfaceMigrationTests {
    @Test
    func `Surface migration moves the captured native container and preserves its children`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let first = VideoSurface(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
      let second = VideoSurface(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
      first.attach(to: player)
      let native = try nativeSurface(player)
      let renderer = VideoSurface(frame: .zero)
      native.addSubview(renderer)
      let handle = player.pointer
      second.attach(to: player)
      #expect(try nativeSurface(player) === native)
      #expect(player.pointer == handle)
      #expect(native.superview === second)
      #expect(first.subviews.isEmpty)
      #expect(renderer.superview === native)
      #expect(native.frame == second.bounds)
      first.detach()
      #expect(native.superview === second)
      second.detach()
      #expect(native.superview == nil)
      #expect(libvlc_media_player_get_nsobject(player.pointer) == nil)
      first.attach(to: player)
      #expect(try nativeSurface(player) === native)
      #expect(renderer.superview === native)
      first.detach()
      await player.shutdown()
    }

    @Test
    func `An obsolete surface can deallocate while its native container continues rendering`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let second = VideoSurface(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
      weak var retired: VideoSurface?
      autoreleasepool {
        let first = VideoSurface(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        retired = first
        first.attach(to: player)
        player.nativePlayerHasStartedPlayback = true
        second.attach(to: player)
      }
      #expect(retired == nil)
      #expect(try nativeSurface(player).superview === second)
      second.detach()
      await player.shutdown()
    }

    @Test
    func `Rejected replacement keeps the current native container mounted`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let surface = VideoSurface(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
      surface.attach(to: player)
      let native = try nativeSurface(player)
      let handle = player.pointer
      player.nativePlayerNeedsReplacementBeforePlayback = true
      player.eventBridge._forcePreparedAttachmentFailureForTesting(afterAttachedCount: 1)
      #expect(throws: VLCError.self) { try player.prepareDrawableForPlayback() }
      #expect(player.pointer == handle)
      #expect(try nativeSurface(player) === native)
      #expect(native.superview === surface)
      player.eventBridge._forcePreparedAttachmentFailureForTesting(afterAttachedCount: nil)
      try player.prepareDrawableForPlayback()
      #expect(try nativeSurface(player) !== native)
      #expect(native.superview == nil)
      #expect(try nativeSurface(player).superview === surface)
      surface.detach()
      await player.shutdown()
    }

    private func nativeSurface(_ player: Player) throws -> VideoSurface {
      let pointer = try #require(libvlc_media_player_get_nsobject(player.pointer))
      return Unmanaged<VideoSurface>.fromOpaque(pointer).takeUnretainedValue()
    }
  }
}
