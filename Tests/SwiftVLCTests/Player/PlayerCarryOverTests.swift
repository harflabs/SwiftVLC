@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

/// Strong-reference probe standing in for a platform view attached via
/// `Player.setDrawable`. `NSObject` because libVLC's `drawable-nsobject`
/// variable expects an Objective-C object pointer.
private final class Probe: NSObject {}

/// Per-player state survival across the playback-free native-handle
/// swap (`setDrawable` → `stop` → `prepareDrawableForPlayback`): overlay
/// configuration, video adjustments, audio routing shadows, viewpoint,
/// drawable release, renderer recast, and the media-list-player rebind.
/// All tests run headless on CI — the swap never starts playback.
extension Integration {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct PlayerCarryOverTests {
    /// Marks the handle for replacement (hosted drawable + stop) and
    /// performs the swap, requiring that the native pointer changed.
    private func forceHandleSwap(on player: Player) throws {
      let oldPointer = player.pointer
      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()
      try #require(
        player.pointer != oldPointer,
        "swap did not replace the native player handle"
      )
    }

    /// libVLC exposes no `libvlc_video_get_marquee_string`, so the text
    /// is asserted through the `_marqueeText` shadow; every integer
    /// option is read back from the replacement handle.
    @Test
    func `Marquee configuration survives the native handle swap`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.withMarquee { marquee in
        marquee.setText("ticker")
        marquee.color = 0xFF0000
        marquee.opacity = 128
        marquee.fontSize = 24
        marquee.x = 10
        marquee.y = 20
        marquee.position = 5
      }

      try forceHandleSwap(on: player)

      let (color, opacity, fontSize, x, y, position) = player.withMarquee {
        ($0.color, $0.opacity, $0.fontSize, $0.x, $0.y, $0.position)
      }
      #expect(color == 0xFF0000)
      #expect(opacity == 128)
      #expect(fontSize == 24)
      #expect(x == 10)
      #expect(y == 20)
      #expect(position == 5)
      #expect(player._marqueeText == "ticker")
    }

    @Test
    func `Logo configuration survives the native handle swap`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.withLogo { logo in
        logo.setFile("/tmp/logo.png")
        logo.x = 15
        logo.y = 25
        logo.opacity = 200
        logo.position = 6
        logo.isEnabled = true
      }

      try forceHandleSwap(on: player)

      let (x, y, opacity, position, isEnabled) = player.withLogo {
        ($0.x, $0.y, $0.opacity, $0.position, $0.isEnabled)
      }
      #expect(x == 15)
      #expect(y == 25)
      #expect(opacity == 200)
      #expect(position == 6)
      #expect(isEnabled)
      #expect(player._logoFile == "/tmp/logo.png")
    }

    /// The float adjustments read back headless, but libVLC does not
    /// persist the adjust *enable* flag without an active video output
    /// (a direct native set+get returns 0 on a `--no-video` instance,
    /// swap or no swap). The swap copies the old handle's read-back, so
    /// the enable flag is asserted for parity across the swap rather
    /// than for the value originally written.
    @Test
    func `Video adjustments survive the native handle swap`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.withAdjustments { adjustments in
        adjustments.isEnabled = true
        adjustments.contrast = 1.5
        adjustments.hue = 30
      }
      let preSwapEnabled = player.withAdjustments { $0.isEnabled }

      try forceHandleSwap(on: player)

      let (isEnabled, contrast, hue) = player.withAdjustments {
        ($0.isEnabled, $0.contrast, $0.hue)
      }
      #expect(isEnabled == preSwapEnabled, "enable flag changed across the swap")
      #expect(abs(contrast - 1.5) < 0.001, "contrast reverted to \(contrast)")
      #expect(abs(hue - 30) < 0.001, "hue reverted to \(hue)")
    }

    @Test
    func `Stereo and mix modes survive the native handle swap`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.stereoMode = .stereo
      player.mixMode = .stereo
      try #require(
        player.stereoMode == .stereo,
        "stereo mode did not reflect the set before the swap"
      )
      try #require(
        player.mixMode == .stereo,
        "mix mode did not reflect the set before the swap"
      )

      try forceHandleSwap(on: player)

      #expect(player.stereoMode == .stereo)
      #expect(player.mixMode == .stereo)
    }

    /// Reads the deinterlace parameters straight from a native handle.
    private func nativeDeinterlace(of pointer: OpaquePointer) -> (state: Int32, mode: String?) {
      var mode: UnsafeMutablePointer<CChar>?
      let state = libvlc_video_get_deinterlace(pointer, &mode)
      defer { mode.map { free($0) } }
      return (state, mode.map { String(cString: $0) })
    }

    /// The deinterlace filter is the one carried item whose native getter
    /// reads back headless (`libvlc_video_get_deinterlace` returns the
    /// forced state and algorithm without a live video output), so it is
    /// asserted as native parity: the replacement handle must read back
    /// exactly what the old handle read before the swap.
    @Test
    func `Deinterlace filter survives the native handle swap with native read-back parity`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.setDeinterlace(state: 1, mode: "blend")

      let preSwap = nativeDeinterlace(of: player.pointer)
      try #require(
        preSwap == (1, "blend"),
        "deinterlace set did not read back natively before the swap: \(preSwap)"
      )

      try forceHandleSwap(on: player)

      let postSwap = nativeDeinterlace(of: player.pointer)
      #expect(
        postSwap == preSwap,
        "replacement handle lost the deinterlace filter: \(postSwap)"
      )
      #expect(player._deinterlaceState == 1)
      #expect(player._deinterlaceMode == "blend")
    }

    /// Teletext and audio routing cannot be verified natively on a
    /// headless handle, so only their shadows are asserted — this test
    /// does not prove native survival. `libvlc_video_get_teletext` reads
    /// the live input's page (a headless set leaves it at the default
    /// 100), `libvlc_audio_output_set` has no getter at all, and
    /// `libvlc_audio_output_device_get` is unstable without a live audio
    /// output (it returns NULL after a headless set). The audio routing
    /// calls can be rejected without a live audio output, so their
    /// shadows are only asserted when the set succeeded.
    @Test
    func `Teletext and audio routing shadows survive the native handle swap (native read-back impossible headless)`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.setTeletextPage(120)

      var audioOutputApplied = false
      do {
        try player.setAudioOutput("dummy")
        audioOutputApplied = true
      } catch {}
      var audioDeviceApplied = false
      do {
        try player.setAudioDevice("test-device")
        audioDeviceApplied = true
      } catch {}

      try forceHandleSwap(on: player)

      #expect(player._teletextPage == 120)
      if audioOutputApplied {
        #expect(player._audioOutputModule == "dummy")
      }
      if audioDeviceApplied {
        #expect(player._audioOutputDevice == "test-device")
      }
    }

    /// libVLC exposes no viewpoint getter (`libvlc_video_update_viewpoint`
    /// is write-only), so native survival across the swap cannot be
    /// verified — only the accumulated `_viewpoint` shadow is asserted.
    @Test
    func `Viewpoint shadow accumulates relative updates and survives the native handle swap`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.updateViewpoint(Viewpoint(yaw: 10, pitch: 5, roll: 0, fieldOfView: 80))
      try player.updateViewpoint(
        Viewpoint(yaw: 5, pitch: -2, roll: 1, fieldOfView: 0),
        absolute: false
      )

      let accumulated = Viewpoint(yaw: 15, pitch: 3, roll: 1, fieldOfView: 80)
      #expect(player._viewpoint == accumulated)

      try forceHandleSwap(on: player)

      #expect(player._viewpoint == accumulated)
    }

    /// A drawable detached while the handle is marked for replacement is
    /// parked in the retained-drawables list so the offloaded release of
    /// the old handle cannot race a vout-thread read; the swap must drain
    /// that list once the release completes, or the view leaks.
    @Test
    func `Swap drains the retained drawable after the offloaded native release`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      weak var weakProbe: Probe?
      let oldPointer = player.pointer

      do {
        let probe = Probe()
        weakProbe = probe
        player.setDrawable(probe)
        player.stop()
        player.setDrawable(nil)
        try player.prepareDrawableForPlayback()
      }

      try #require(
        player.pointer != oldPointer,
        "swap did not replace the native player handle"
      )
      #expect(player.drawable == nil)
      try #require(
        await poll(timeout: .seconds(5), until: { weakProbe == nil }),
        "Waiting for: detached drawable released after the offloaded native release"
      )
    }

    @Test
    func `Detaching the drawable without a swap releases it`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      weak var weakProbe: Probe?

      do {
        let probe = Probe()
        weakProbe = probe
        player.setDrawable(probe)
        player.setDrawable(nil)
      }

      #expect(player.drawable == nil)
      try #require(
        await poll(timeout: .seconds(5), until: { weakProbe == nil }),
        "Waiting for: detached drawable released without a swap"
      )
    }

    @Test
    func `recast on a never-played player applies the renderer without replacing the handle`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let oldPointer = player.pointer

      try await player.recast(to: nil)

      #expect(
        player.pointer == oldPointer,
        "recast replaced the handle of a never-played player"
      )
      #expect(player.selectedRenderer == nil)
    }

    /// The native list player stores the raw `libvlc_media_player_t*`,
    /// so every handle replacement must re-bind it — otherwise the list
    /// player keeps driving the released pointer.
    @Test
    func `Attached media list player drives the replacement handle after a swap`() throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let listPlayer = MediaListPlayer(instance: instance)
      listPlayer.mediaPlayer = player

      try forceHandleSwap(on: player)

      // Returned +1 retained per the libVLC header; balance it here.
      let bound = libvlc_media_list_player_get_media_player(listPlayer.pointer)
      defer { bound.map { libvlc_media_player_release($0) } }
      #expect(
        bound == player.pointer,
        "list player still bound to the released handle"
      )
    }
  }
}
