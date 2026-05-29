#if os(iOS) || os(macOS)
@_spi(PrivateMacOSPiP) @testable import SwiftVLC
import AVFoundation
import SwiftUI
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Covers `PiPVideoView` paths that don't require a live SwiftUI
/// scene: the `init`, `makeCoordinator`, and the static dismantle
/// hook that SwiftUI calls when the view is removed from the tree.
///
/// The full `makeUIView` / `makeNSView` path is harder to hit without
/// a SwiftUI host — we drive the coordinator directly instead, which
/// is where the actual lifecycle logic lives.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPVideoViewTests {
    @Test
    func `Init without binding does not crash`() {
      let player = Player(instance: TestInstance.shared)
      _ = PiPVideoView(player)
    }

    @Test
    func `Init with controller binding does not crash`() {
      let player = Player(instance: TestInstance.shared)
      let storage = Box<PiPController?>(nil)
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: { storage.value = $0 }
      )
      _ = PiPVideoView(player, controller: binding)
    }

    @Test
    func `makeCoordinator returns a usable Coordinator`() {
      let player = Player(instance: TestInstance.shared)
      let view = PiPVideoView(player)

      let coordinator = view.makeCoordinator()
      // Fresh coordinator has no references.
      #expect(coordinator.pipController == nil)
      #expect(coordinator.player == nil)
    }

    /// Dismantle on an empty coordinator is a safe no-op: no
    /// controller to stop and no drawable attachment to clear.
    @Test
    func `dismantle on empty coordinator is a no-op`() {
      let player = Player(instance: TestInstance.shared)
      let view = PiPVideoView(player)
      let coordinator = view.makeCoordinator()

      #if canImport(UIKit)
      let container = UIView()
      PiPVideoView.dismantleUIView(container, coordinator: coordinator)
      #elseif canImport(AppKit)
      let container = MacNativePiPHostView()
      PiPVideoView.dismantleNSView(container, coordinator: coordinator)
      #endif
    }

    /// Dismantle with a controller attached must stop it and clear
    /// coordinator-owned controller state.
    @Test
    func `dismantle with attached controller clears state`() {
      let player = Player(instance: TestInstance.shared)
      let view = PiPVideoView(player)
      let coordinator = view.makeCoordinator()

      // Simulate what makeUIView/makeNSView would do: attach a
      // controller to the coordinator.
      let controller = PiPController(player: player)
      coordinator.pipController = controller
      coordinator.player = player

      #if canImport(UIKit)
      let container = UIView()
      PiPVideoView.dismantleUIView(container, coordinator: coordinator)
      #elseif canImport(AppKit)
      let container = MacNativePiPHostView()
      PiPVideoView.dismantleNSView(container, coordinator: coordinator)
      #endif

      #expect(coordinator.pipController == nil)
    }

    #if canImport(UIKit)
    @Test
    func `iOS native PiP host attaches drawable child`() {
      let player = Player(instance: TestInstance.shared)
      let host = IOSNativePiPHostView()

      host.attach(to: player)
      #expect(player.drawable === host.drawableView)

      host.detach()
      #expect(player.drawable == nil)
    }

    @Test
    func `iOS native PiP drawable exposes VLC PiP selectors`() {
      let view = IOSNativePiPDrawableView()

      #expect(view.responds(to: NSSelectorFromString("mediaController")))
      #expect(view.responds(to: NSSelectorFromString("pictureInPictureReady")))
      #expect(view.responds(to: NSSelectorFromString("canStartPictureInPictureAutomaticallyFromInline")))
      if let protocolObject = NSProtocolFromString("VLCPictureInPictureDrawable") {
        // Bind `conforms(to:)` to a plain Bool first. Calling it through an
        // `AnyObject` (below) inside the `#expect` autoclosure makes SILGen
        // emit a reabstraction thunk that crashes the iOS compiler (Swift
        // 6.3.2); hoisting the call out of the autoclosure sidesteps it, and
        // we keep both conformance checks consistent.
        let conformsToDrawable = view.conforms(to: protocolObject)
        #expect(conformsToDrawable)
      } else {
        Issue.record("VLCPictureInPictureDrawable protocol is not registered")
      }

      let mediaController = view.mediaController()
      if let protocolObject = NSProtocolFromString("VLCPictureInPictureMediaControlling") {
        let conformsToMediaControlling = mediaController.conforms(to: protocolObject)
        #expect(conformsToMediaControlling)
      } else {
        Issue.record("VLCPictureInPictureMediaControlling protocol is not registered")
      }
    }

    @Test
    func `iOS native PiP drawable sizes VLC content to its bounds`() {
      let view = IOSNativePiPDrawableView()
      view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
      let vlcSubview = UIView()
      view.addSubview(vlcSubview)
      view.layoutIfNeeded()

      #expect(vlcSubview.frame.size == CGSize(width: 640, height: 360))
      #expect(vlcSubview.autoresizingMask == [.flexibleWidth, .flexibleHeight])

      view.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
      view.layoutIfNeeded()

      #expect(vlcSubview.frame.size == CGSize(width: 480, height: 270))
      #expect(vlcSubview.autoresizingMask == [.flexibleWidth, .flexibleHeight])
    }

    @Test
    func `iOS native PiP media controller reports playback intent`() {
      let player = Player(instance: TestInstance.shared)
      let mediaController = IOSNativePiPMediaController()
      mediaController.player = player

      #expect(mediaController.isMediaPlaying() == false)

      player.setPlaybackIntentFromExternalControl(true)
      #expect(mediaController.isMediaPlaying() == true)

      player.setPlaybackIntentFromExternalControl(false)
      #expect(mediaController.isMediaPlaying() == false)
    }

    @Test
    func `iOS native PiP controller delegates to native backend`() {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      let controller = PiPController(player: player, nativeBackend: backend)

      controller.start()
      controller.invalidatePictureInPicturePlaybackState()
      controller.stop()
      controller.handleNativePictureInPictureReady()
      controller.handleNativePictureInPictureActiveChanged(true)
      #expect(controller.isActive == true)
      controller.handleNativePictureInPictureActiveChanged(false)
      #expect(controller.isActive == false)
      controller.handleNativePictureInPictureSetPlaying(true)
      #expect(controller._pipPlaybackActiveForTesting() == true)
    }

    /// Regression: a player swap builds a new controller on the *same*
    /// shared native backend, then releases the old controller. The old
    /// controller's deinit must not null the successor's ownership, or the
    /// new controller's PiP state callbacks go silently dead.
    @Test
    func `Controller deinit does not clobber a successor's backend claim`() async {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()

      var first: PiPController? = PiPController(player: player, nativeBackend: backend)
      #expect(backend.owner === first)

      let second = PiPController(player: player, nativeBackend: backend)
      #expect(backend.owner === second)

      first = nil
      await Task.yield()

      #expect(backend.owner === second)
      withExtendedLifetime(second) {}
    }

    /// Teardown of the native backend's window-controller wiring must be
    /// idempotent, and every private selector / KVC access must be gated by
    /// `responds(to:)` so a non-conforming controller (or none) never
    /// crashes. After `detach()` readiness is cleared regardless of whether
    /// a controller was installed.
    @Test
    func `iOS native backend teardown is idempotent and selector-gated`() {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      backend.attach(to: player)

      // A non-conforming controller must not crash.
      backend.handlePictureInPictureReady(NSObject())

      // Start/stop/invalidate are safe whether or not a controller installed.
      backend.start()
      backend.stop()
      backend.invalidatePlaybackState()

      // Detach clears readiness and is idempotent.
      backend.detach()
      backend.detach()
      #expect(backend.isPossible == false)
      #expect(backend.isActive == false)
    }

    /// iOS native play/pause must route through the controller — engaging
    /// the AVKit-transient pause debouncer and PiP playback-state
    /// reconciliation — rather than poking the player directly. Verifies the
    /// shared media controller is wired to its owning controller and that a
    /// native pause flows through it.
    @Test
    func `iOS media controller routes pause through the controller`() async {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      let controller = PiPController(player: player, nativeBackend: backend)

      #expect(backend.mediaController.owner === controller)

      // Prime PiP playback state to "playing", then a native pause must flow
      // through the controller and flip it back off.
      controller.handleNativePictureInPictureSetPlaying(true)
      #expect(controller._pipPlaybackActiveForTesting() == true)

      backend.mediaController.pause()
      await Task.yield()
      #expect(controller._pipPlaybackActiveForTesting() == false)

      withExtendedLifetime(controller) {}
    }
    #endif

    @Test
    func `dismantle fallback stops controller and clears binding`() async {
      #if canImport(AppKit)
      let player = Player(instance: TestInstance.shared)
      let storage = Box<PiPController?>(nil)
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: { storage.value = $0 }
      )
      let view = PiPVideoView(player, controller: binding)
      let coordinator = view.makeCoordinator()
      let controller = PiPController(player: player)

      storage.value = controller
      coordinator.pipController = controller
      coordinator.controllerBinding = binding

      PiPVideoView.dismantleNSView(NSView(), coordinator: coordinator)
      await Task.yield()

      #expect(coordinator.pipController == nil)
      #expect(coordinator.controllerBinding == nil)
      #expect(storage.value == nil)
      #else
      #expect(Bool(true))
      #endif
    }

    #if canImport(AppKit)
    @Test
    func `macOS native PiP host attaches drawable child`() {
      let player = Player(instance: TestInstance.shared)
      let host = MacNativePiPHostView()

      host.attach(to: player)
      #expect(player.drawable === host.drawableView)

      host.detach()
      #expect(player.drawable == nil)
    }

    @Test
    func `macOS native PiP drawable attaches and detaches player drawable`() {
      let player = Player(instance: TestInstance.shared)
      let view = MacNativePiPDrawableView()

      view.attach(to: player)
      #expect(player.drawable === view)

      view.detach()
      #expect(player.drawable == nil)
    }

    @Test
    func `macOS dismantle detaches native PiP drawable and clears controller`() {
      let player = Player(instance: TestInstance.shared)
      let host = MacNativePiPHostView()
      let view = PiPVideoView(player)
      let coordinator = view.makeCoordinator()
      let controller = PiPController(player: player, nativeBackend: host.nativePiPBackend)

      host.attach(to: player)
      coordinator.player = player
      coordinator.pipController = controller

      PiPVideoView.dismantleNSView(host, coordinator: coordinator)

      #expect(player.drawable == nil)
      #expect(coordinator.pipController == nil)

      host.detach()
      #expect(player.drawable == nil)
    }

    @Test
    func `macOS native PiP drawable does not expose VLC AVKit PiP callbacks`() {
      let view = MacNativePiPDrawableView()

      #expect(view.responds(to: NSSelectorFromString("pictureInPictureReady")) == false)
      #expect(view.responds(to: NSSelectorFromString("mediaController")) == false)
      #expect(view.responds(to: NSSelectorFromString("canStartPictureInPictureAutomaticallyFromInline")) == false)
    }

    @Test
    func `macOS native PiP drawable exposes VLC embedding callbacks`() {
      let view = MacNativePiPDrawableView()

      #expect(view.responds(to: NSSelectorFromString("addVoutSubview:")))
      #expect(view.responds(to: NSSelectorFromString("removeVoutSubview:")))
    }

    @Test
    func `macOS native PiP drawable sizes VLC content to its bounds`() {
      let view = MacNativePiPDrawableView()
      view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
      let vlcSubview = NSView()
      view.addSubview(vlcSubview)
      view.layoutSubtreeIfNeeded()

      #expect(vlcSubview.frame.size == CGSize(width: 640, height: 360))
      #expect(vlcSubview.autoresizingMask == [.width, .height])

      view.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
      view.layoutSubtreeIfNeeded()

      #expect(vlcSubview.frame.size == CGSize(width: 480, height: 270))
      #expect(vlcSubview.autoresizingMask == [.width, .height])
    }

    @Test
    func `macOS native PiP drawable removes VLC subviews only when owned`() {
      let view = MacNativePiPDrawableView()
      let ownedSubview = NSView()
      let externalSubview = NSView()

      view.addVoutSubview(ownedSubview)
      view.removeVoutSubview(externalSubview)
      #expect(ownedSubview.superview === view)

      view.removeVoutSubview(ownedSubview)
      #expect(ownedSubview.superview == nil)
    }

    @Test
    func `macOS native PiP drawable lays out direct sublayers`() {
      let view = MacNativePiPDrawableView()
      view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
      let sublayer = CALayer()

      view.layer?.addSublayer(sublayer)
      view.restoreVLCContentLayout()

      #expect(sublayer.frame.size == CGSize(width: 320, height: 180))
    }

    @Test
    func `macOS native PiP drawable rebinds stale drawable on first nonzero layout`() {
      let player = Player(instance: TestInstance.shared)
      let view = MacNativePiPDrawableView()
      let staleDrawable = NSView()

      view.attach(to: player)
      player.setDrawable(staleDrawable, owner: view)
      #expect(player.drawable === staleDrawable)

      view.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
      view.layout()

      #expect(player.drawable === view)

      view.detach()
    }

    @Test
    func `macOS native PiP restore repeats full-size VLC content layout`() async {
      let host = MacNativePiPHostView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
      let drawable = host.drawableView
      let vlcSubview = PiPReshapeProbeView()

      drawable.addVoutSubview(vlcSubview)
      host.layoutSubtreeIfNeeded()

      func restoreFromPiPSize() {
        drawable.removeFromSuperview()
        drawable.frame = CGRect(x: 0, y: 0, width: 426, height: 240)
        vlcSubview.frame = drawable.bounds

        host.restoreDrawableView(drawable)
      }

      restoreFromPiPSize()
      restoreFromPiPSize()

      #expect(drawable.superview === host)
      #expect(drawable.frame.size == host.bounds.size)
      #expect(vlcSubview.frame.size == host.bounds.size)
      #expect(vlcSubview.reshapeCount >= 2)

      await Task.yield()

      #expect(drawable.superview === host)
      #expect(drawable.frame.size == host.bounds.size)
      #expect(vlcSubview.frame.size == host.bounds.size)
      #expect(vlcSubview.reshapeCount >= 3)
    }

    @Test
    func `macOS native PiP rejects instances without video output`() throws {
      let instance = try VLCInstance(arguments: ["--no-video-title-show", "--no-video", "--no-audio", "--quiet"])
      let player = Player(instance: instance)
      let backend = MacNativePiPBackend()

      backend.attach(to: player)

      #expect(backend.isPossible == false)
    }

    @Test
    func `macOS native PiP media controller reports playback intent`() {
      let player = Player(instance: TestInstance.shared)
      let mediaController = MacNativePiPMediaController()
      mediaController.player = player

      #expect(mediaController.isMediaPlaying() == false)

      player.setPlaybackIntentFromExternalControl(true)
      #expect(mediaController.isMediaPlaying() == true)

      player.setPlaybackIntentFromExternalControl(false)
      #expect(mediaController.isMediaPlaying() == false)
    }

    @Test
    func `macOS native PiP backend start stop without media are safe no-ops`() {
      let initialAllowsPrivateAPI = PiPController.allowsPrivateMacOSAPI
      defer { PiPController.allowsPrivateMacOSAPI = initialAllowsPrivateAPI }
      PiPController.allowsPrivateMacOSAPI = false

      let player = Player(instance: TestInstance.shared)
      let backend = MacNativePiPBackend()

      backend.attach(to: player)
      backend.start()
      backend.invalidatePlaybackState()
      backend.stop()

      #expect(backend.isPossible == false)
      #expect(backend.isActive == false)

      backend.detach()

      #expect(backend.isPossible == false)
      #expect(backend.isActive == false)
    }

    @Test
    func `macOS native PiP backend remains unavailable for no-video instances even when private API is enabled`() throws {
      let initialAllowsPrivateAPI = PiPController.allowsPrivateMacOSAPI
      defer { PiPController.allowsPrivateMacOSAPI = initialAllowsPrivateAPI }
      PiPController.allowsPrivateMacOSAPI = true

      let instance = try VLCInstance(arguments: ["--no-video-title-show", "--no-video", "--no-audio", "--quiet"])
      let player = Player(instance: instance)
      let backend = MacNativePiPBackend()

      backend.attach(to: player)

      #expect(backend.isPossible == false)
    }

    @Test
    func `macOS native PiP backend start with media but unavailable host is a no-op`() throws {
      let initialAllowsPrivateAPI = PiPController.allowsPrivateMacOSAPI
      defer { PiPController.allowsPrivateMacOSAPI = initialAllowsPrivateAPI }
      PiPController.allowsPrivateMacOSAPI = false

      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let backend = MacNativePiPBackend()

      backend.attach(to: player)
      backend.start()

      #expect(backend.isPossible == false)
      #expect(backend.isActive == false)
    }

    @Test
    func `macOS PiP controller delegates to native backend`() {
      let initialAllowsPrivateAPI = PiPController.allowsPrivateMacOSAPI
      defer { PiPController.allowsPrivateMacOSAPI = initialAllowsPrivateAPI }
      PiPController.allowsPrivateMacOSAPI = false

      let player = Player(instance: TestInstance.shared)
      let backend = MacNativePiPBackend()
      let controller = PiPController(player: player, nativeBackend: backend)

      controller.start()
      controller.invalidatePictureInPicturePlaybackState()
      controller.stop()
      controller.handleNativePictureInPictureReady()
      controller.handleNativePictureInPictureActiveChanged(true)
      #expect(controller.isActive == true)
      controller.handleNativePictureInPictureActiveChanged(false)
      #expect(controller.isActive == false)
      controller.handleNativePictureInPictureSetPlaying(true)
      #expect(controller._pipPlaybackActiveForTesting() == true)
    }

    /// Regression: a player swap builds a new controller on the *same*
    /// shared native backend, then releases the old controller. The old
    /// controller's deinit must not null the successor's ownership, or the
    /// new controller's PiP state callbacks go silently dead.
    @Test
    func `macOS controller deinit does not clobber a successor's backend claim`() async {
      let player = Player(instance: TestInstance.shared)
      let backend = MacNativePiPBackend()

      var first: PiPController? = PiPController(player: player, nativeBackend: backend)
      #expect(backend.owner === first)

      let second = PiPController(player: player, nativeBackend: backend)
      #expect(backend.owner === second)

      first = nil
      await Task.yield()

      #expect(backend.owner === second)
      withExtendedLifetime(second) {}
    }

    @Test
    func `macOS native PiP media controller defaults without player`() async {
      let mediaController = MacNativePiPMediaController()
      let didComplete = Box(false)

      mediaController.play()
      mediaController.pause()
      mediaController.seek(by: 250) {
        didComplete.value = true
      }

      await Task.yield()

      #expect(didComplete.value)
      #expect(mediaController.mediaLength() == -1)
      #expect(mediaController.mediaTime() == 0)
      #expect(mediaController.isMediaSeekable() == false)
      #expect(mediaController.isMediaPlaying() == false)
    }

    @Test
    func `macOS native PiP media controller reads player defaults and completes seek`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        currentTime: .seconds(5),
        duration: .seconds(10),
        isSeekable: true
      )

      let mediaController = MacNativePiPMediaController()
      mediaController.player = player
      let didComplete = Box(false)

      mediaController.play()
      mediaController.pause()
      mediaController.seek(by: -10000) {
        didComplete.value = true
      }

      await Task.yield()
      player.setPlaybackIntentFromExternalControl(false)

      #expect(didComplete.value)
      #expect(player.currentTime == .zero)
      #expect(mediaController.mediaLength() >= -1)
      #expect(mediaController.mediaTime() >= 0)
      _ = mediaController.isMediaSeekable()
      #expect(mediaController.isMediaPlaying() == false)
    }

    @Test
    func `macOS native PiP media controller resumes active player state`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: false)

      let mediaController = MacNativePiPMediaController()
      mediaController.player = player

      mediaController.play()
      await Task.yield()

      #expect(player.isPlaybackRequestedActive)
    }

    @Test(.tags(.async, .media), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `macOS native PiP media controller play resumes paused playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      let mediaController = MacNativePiPMediaController()
      mediaController.player = player

      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")

      player.pause()
      try #require(await poll(until: { player.state == .paused }), "Waiting for: player.state == .paused")

      mediaController.play()
      try #require(await poll(until: { mediaController.isMediaPlaying() }), "Waiting for: PiP media controller playback")

      player.stop()
    }

    @Test
    func `SwiftUI host creates and updates native PiP view`() async throws {
      let firstPlayer = Player(instance: TestInstance.shared)
      let secondPlayer = Player(instance: TestInstance.shared)
      let storage = Box<PiPController?>(nil)
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: { storage.value = $0 }
      )
      let host = NSHostingView(rootView: PiPVideoView(firstPlayer, controller: binding))

      host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
      host.layoutSubtreeIfNeeded()
      await Task.yield()

      let initialContainer = try #require(host.firstDescendant(ofType: MacNativePiPHostView.self))
      #expect(firstPlayer.drawable === initialContainer.drawableView)
      #expect(storage.value != nil)

      host.rootView = PiPVideoView(secondPlayer, controller: binding)
      host.layoutSubtreeIfNeeded()
      await Task.yield()

      let updatedContainer = try #require(host.firstDescendant(ofType: MacNativePiPHostView.self))
      #expect(firstPlayer.drawable == nil)
      #expect(secondPlayer.drawable === updatedContainer.drawableView)
      #expect(storage.value != nil)
    }
    #endif
  }
}

/// Reference-cell backing for a test-built SwiftUI `Binding`. Avoids
/// pulling in `@State`, which requires a real view hierarchy.
private final class Box<T> {
  var value: T
  init(_ initial: T) {
    value = initial
  }
}

#if canImport(AppKit)
@MainActor
private final class PiPReshapeProbeView: NSView {
  var reshapeCount = 0

  @objc(reshape)
  func reshapeForTesting() {
    reshapeCount += 1
  }
}
#endif
#endif
