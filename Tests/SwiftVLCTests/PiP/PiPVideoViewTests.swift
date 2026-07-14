#if os(iOS) || os(macOS)
@_spi(PrivateMacOSPiP) @testable import SwiftVLC
import AVFoundation
import CLibVLC
import CustomDump
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

    @Test
    func `Init with policy knobs does not crash`() {
      let player = Player(instance: TestInstance.shared)
      _ = PiPVideoView(
        player,
        startsAutomaticallyFromInline: false,
        managesAudioSession: false
      )
      _ = PiPVideoView(
        player,
        startsAutomaticallyFromInline: true,
        managesAudioSession: true
      )
    }

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

      coordinator.pipController = controller
      coordinator.publishController(controller, to: binding)
      await coordinator.waitForControllerBindingPublication()
      #expect(storage.value === controller)

      PiPVideoView.dismantleNSView(NSView(), coordinator: coordinator)
      await coordinator.waitForControllerBindingPublication()

      #expect(coordinator.pipController == nil)
      #expect(coordinator.controllerBinding == nil)
      #expect(storage.value == nil)
      #else
      #expect(Bool(true))
      #endif
    }

    #if canImport(AppKit)
    private func nativeDrawable(of player: Player) -> UnsafeMutableRawPointer? {
      libvlc_media_player_get_nsobject(player.pointer)
    }

    /// Pinned libVLC's `macosx` vout copies `drawable-nsobject` into its
    /// strong `sys->container` once at vout open. Replacing the Player
    /// variable cannot redirect that open vout, so this probe models the
    /// immutable native reference without depending on decoder timing.
    @Test
    func `macOS same-player make before dismantle reparents the vout-latched drawable`() {
      let player = Player(instance: TestInstance.shared)
      let originalHost = MacNativePiPHostView()
      originalHost.attach(to: player)
      let originalDrawable = originalHost.drawableView
      let originalBackend = originalHost.nativePiPBackend
      let openVout = OpenMacVoutContainerProbe(container: originalDrawable)
      let nativeHandle = player.pointer
      player.nativePlayerHasStartedPlayback = true

      let successorHost = MacNativePiPHostView()
      successorHost.attach(to: player)
      originalHost.detach()

      #expect(successorHost.drawableView === openVout.container)
      #expect(successorHost.drawableView === originalDrawable)
      #expect(originalDrawable.superview === successorHost)
      #expect(successorHost.nativePiPBackend === originalBackend)
      #expect(originalBackend.hostView === successorHost)
      #expect(originalBackend.drawableView === originalDrawable)
      #expect(player.drawable === originalDrawable)
      #expect(nativeDrawable(of: player) == Unmanaged.passUnretained(originalDrawable).toOpaque())
      #expect(player.pointer == nativeHandle)
    }

    @Test
    func `macOS same-player dismantle before make preserves and reparents the vout-latched drawable`() {
      let player = Player(instance: TestInstance.shared)
      let originalHost = MacNativePiPHostView()
      originalHost.attach(to: player)
      let originalDrawable = originalHost.drawableView
      let originalBackend = originalHost.nativePiPBackend
      let openVout = OpenMacVoutContainerProbe(container: originalDrawable)
      let nativeHandle = player.pointer
      player.nativePlayerHasStartedPlayback = true

      originalHost.detach()

      #expect(player.drawable === openVout.container)
      #expect(originalDrawable.superview == nil)

      let successorHost = MacNativePiPHostView()
      successorHost.attach(to: player)

      #expect(successorHost.drawableView === openVout.container)
      #expect(successorHost.drawableView === originalDrawable)
      #expect(originalDrawable.superview === successorHost)
      #expect(successorHost.nativePiPBackend === originalBackend)
      #expect(originalBackend.hostView === successorHost)
      #expect(originalBackend.drawableView === originalDrawable)
      #expect(player.drawable === originalDrawable)
      #expect(nativeDrawable(of: player) == Unmanaged.passUnretained(originalDrawable).toOpaque())
      #expect(player.pointer == nativeHandle)
    }

    @Test
    func `macOS observed external vout also leases the exact drawable`() {
      let player = Player(instance: TestInstance.shared)
      let originalHost = MacNativePiPHostView()
      originalHost.attach(to: player)
      let originalDrawable = originalHost.drawableView
      let originalBackend = originalHost.nativePiPBackend
      player.activeVideoOutputs = 1

      originalHost.detach()

      #expect(player.drawable === originalDrawable)
      #expect(originalDrawable.superview == nil)

      let successorHost = MacNativePiPHostView()
      successorHost.attach(to: player)

      #expect(successorHost.drawableView === originalDrawable)
      #expect(successorHost.nativePiPBackend === originalBackend)
      #expect(originalDrawable.superview === successorHost)
    }

    @Test
    func `macOS active same-player host churn keeps one drawable and backend`() {
      let player = Player(instance: TestInstance.shared)
      let result = churnMacHosts(for: player, count: 128)

      #expect(result.currentHost.drawableView === result.originalDrawable)
      #expect(result.currentHost.nativePiPBackend === result.originalBackend)
      #expect(player.drawable === result.originalDrawable)
      #expect(nativeDrawable(of: player) == Unmanaged.passUnretained(result.originalDrawable).toOpaque())
      #expect(player.pointer == result.nativeHandle)
      #expect(player.retainedDrawablesUntilNativePlayerRelease.isEmpty)
      #expect(
        result.retiredHosts.enumerated().compactMap { index, host in
          host.value == nil ? nil : index
        } == []
      )
      withExtendedLifetime(result.currentHost) {}
    }

    @Test
    func `macOS host churn releases drawables when no vout can have opened`() {
      let player = Player(instance: TestInstance.shared)
      var retiredDrawables: [MacWeakBox<MacNativePiPDrawableView>] = []

      for _ in 0..<64 {
        autoreleasepool {
          let host = MacNativePiPHostView()
          host.attach(to: player)
          let drawable = host.drawableView
          host.detach()
          retiredDrawables.append(MacWeakBox(drawable))
        }
      }

      #expect(retiredDrawables.allSatisfy { $0.value == nil })
      #expect(player.drawable == nil)
      #expect(nativeDrawable(of: player) == nil)
      #expect(player.retainedDrawablesUntilNativePlayerRelease.isEmpty)
      withExtendedLifetime(player) {}
    }

    @Test
    func `macOS different-player update isolates drawable backend and native pointer`() {
      let firstPlayer = Player(instance: TestInstance.shared)
      let secondPlayer = Player(instance: TestInstance.shared)
      let host = MacNativePiPHostView()
      host.attach(to: firstPlayer)
      let firstDrawable = host.drawableView
      let firstBackend = host.nativePiPBackend
      let openVout = OpenMacVoutContainerProbe(container: firstDrawable)
      firstPlayer.nativePlayerHasStartedPlayback = true

      host.attach(to: secondPlayer)
      let secondDrawable = host.drawableView
      let secondBackend = host.nativePiPBackend

      #expect(firstDrawable === openVout.container)
      #expect(firstDrawable !== secondDrawable)
      #expect(firstBackend !== secondBackend)
      #expect(firstPlayer.drawable == nil)
      #expect(nativeDrawable(of: firstPlayer) == nil)
      #expect(firstBackend.mediaController.player == nil)
      #expect(firstBackend.hostView == nil)
      #expect(firstBackend.drawableView == nil)
      #expect(firstPlayer.retainedDrawablesUntilNativePlayerRelease.count == 1)
      #expect(secondPlayer.drawable === secondDrawable)
      #expect(nativeDrawable(of: secondPlayer) == Unmanaged.passUnretained(secondDrawable).toOpaque())
      #expect(secondBackend.mediaController.player === secondPlayer)
      #expect(secondBackend.hostView === host)
      #expect(secondBackend.drawableView === secondDrawable)

      host.detach()
    }

    @Test
    func `macOS detached stale host cannot repurpose an orphaned backend`() {
      let firstPlayer = Player(instance: TestInstance.shared)
      let secondPlayer = Player(instance: TestInstance.shared)
      let host = MacNativePiPHostView()
      host.attach(to: firstPlayer)
      let firstDrawable = host.drawableView
      let firstBackend = host.nativePiPBackend
      firstPlayer.nativePlayerHasStartedPlayback = true
      host.detach()

      host.attach(to: secondPlayer)
      let secondDrawable = host.drawableView

      #expect(firstPlayer.drawable === firstDrawable)
      #expect(nativeDrawable(of: firstPlayer) == Unmanaged.passUnretained(firstDrawable).toOpaque())
      #expect(firstBackend.mediaController.player === firstPlayer)
      #expect(firstBackend.hostView == nil)
      #expect(firstBackend.drawableView == nil)
      #expect(host.nativePiPBackend !== firstBackend)
      #expect(secondDrawable !== firstDrawable)
      #expect(secondPlayer.drawable === secondDrawable)
      #expect(host.nativePiPBackend.mediaController.player === secondPlayer)
    }

    @Test
    func `macOS orphaned active drawable does not retain controller or player`() async throws {
      weak var releasedController: PiPController?
      weak var releasedPlayer: Player?

      do {
        var player: Player? = Player(instance: TestInstance.shared)
        releasedPlayer = player
        let requiredPlayer = try #require(player)
        let host = MacNativePiPHostView()
        host.attach(to: requiredPlayer)
        requiredPlayer.nativePlayerHasStartedPlayback = true

        var controller: PiPController? = PiPController(
          player: requiredPlayer,
          nativeBackend: host.nativePiPBackend
        )
        releasedController = controller

        host.detach()
        controller = nil
        await Task.yield()

        #expect(releasedController == nil)
        #expect(host.nativePiPBackend.owner == nil)
        player = nil
      }

      #expect(releasedPlayer == nil)
    }

    @Test
    func `macOS successor controller claims adopted backend and requested policy`() async {
      let player = Player(instance: TestInstance.shared)
      let originalHost = MacNativePiPHostView()
      originalHost.attach(to: player)
      let backend = originalHost.nativePiPBackend
      var originalController: PiPController? = PiPController(
        player: player,
        nativeBackend: backend
      )
      weak var releasedController: PiPController?
      releasedController = originalController
      player.nativePlayerHasStartedPlayback = true

      originalHost.detach()
      originalController = nil
      await Task.yield()

      #expect(releasedController == nil)
      #expect(backend.owner == nil)

      let successorHost = MacNativePiPHostView()
      successorHost.attach(to: player)
      let successorController = PiPController(
        player: player,
        nativeBackend: successorHost.nativePiPBackend,
        startsAutomaticallyFromInline: false,
        managesAudioSession: false
      )

      #expect(successorHost.nativePiPBackend === backend)
      #expect(backend.owner === successorController)
      #expect(successorController.startsAutomaticallyFromInline == false)
      #expect(successorController.managesAudioSession == false)
      withExtendedLifetime(successorController) {}
    }

    @Test
    func `macOS native PiP host attaches drawable child`() {
      let player = Player(instance: TestInstance.shared)
      let host = MacNativePiPHostView()

      host.attach(to: player)
      #expect(player.drawable === host.drawableView)

      host.detach()
      #expect(player.drawable == nil)

      host.attach(to: player)
      #expect(player.drawable === host.drawableView)
      #expect(host.nativePiPBackend.hostView === host)
      #expect(host.nativePiPBackend.drawableView === host.drawableView)

      host.detach()
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
    func `macOS private PiP close restores the drawable before dismissal`() async {
      let player = Player(instance: TestInstance.shared)
      let host = MacNativePiPHostView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
      let drawable = host.drawableView
      let controller = MacPrivatePiPViewControllerProbe()
      let presenter = MacPrivatePiPPresenter(
        pictureInPictureViewControllerFactory: { controller }
      )
      let mediaController = MacNativePiPMediaController()
      mediaController.player = player
      var activeStates: [Bool] = []

      let didStart = presenter.start(
        player: player,
        hostView: host,
        drawableView: drawable,
        mediaController: mediaController,
        onActiveChanged: { activeStates.append($0) },
        onPlay: {},
        onPause: {}
      )

      #expect(didStart)
      #expect(presenter.isActive)
      #expect(controller.presentedViewController?.view === drawable)
      #expect(drawable.superview == nil)

      presenter.stop()

      #expect(presenter.isActive == false)
      #expect(drawable.superview === host)
      #expect(drawable.frame == host.bounds)

      await Task.yield()

      #expect(drawable.superview === host)
      #expect(controller.dismissCount == 1)
      expectNoDifference(activeStates, [true, false])
    }

    @Test
    func `macOS private PiP delegate prepares the presenter for system close`() throws {
      let player = Player(instance: TestInstance.shared)
      let host = MacNativePiPHostView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
      let drawable = host.drawableView
      let controller = MacPrivatePiPViewControllerProbe()
      let presenter = MacPrivatePiPPresenter(
        pictureInPictureViewControllerFactory: { controller }
      )
      let mediaController = MacNativePiPMediaController()
      mediaController.player = player
      var activeStates: [Bool] = []

      let didStart = presenter.start(
        player: player,
        hostView: host,
        drawableView: drawable,
        mediaController: mediaController,
        onActiveChanged: { activeStates.append($0) },
        onPlay: {},
        onPause: {}
      )
      #expect(didStart)

      let delegate = try #require(controller.delegate as? MacPrivatePiPDelegate)
      #expect(delegate.shouldClose())
      delegate.willClose()
      delegate.didClose()

      #expect(drawable.superview === host)
      #expect(presenter.isActive == false)
      expectNoDifference(activeStates, [true, false])
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

private final class OpenMacVoutContainerProbe {
  let container: MacNativePiPDrawableView

  init(container: MacNativePiPDrawableView) {
    self.container = container
  }
}

private final class MacWeakBox<T: AnyObject> {
  weak var value: T?

  init(_ value: T?) {
    self.value = value
  }
}

@MainActor
private final class MacPrivatePiPViewControllerProbe: NSViewController {
  @objc dynamic var delegate: NSObject?
  @objc dynamic var replacementWindow: NSWindow?
  @objc dynamic var replacementRect: NSValue?
  @objc dynamic var playing = false
  @objc dynamic var aspectRatio: NSValue?

  private(set) var presentedViewController: NSViewController?
  private(set) var dismissCount = 0

  @objc(presentViewControllerAsPictureInPicture:)
  func presentAsPictureInPicture(_ viewController: NSViewController) {
    presentedViewController = viewController
  }

  @objc(dismissPictureInPictureWithCompletionHandler:)
  func dismissPictureInPicture(
    completion: @escaping @convention(block) () -> Void
  ) {
    dismissCount += 1
    completion()
  }
}

private struct MacHostChurnResult {
  let currentHost: MacNativePiPHostView
  let originalDrawable: MacNativePiPDrawableView
  let originalBackend: MacNativePiPBackend
  let nativeHandle: OpaquePointer
  let retiredHosts: [MacWeakBox<MacNativePiPHostView>]
}

@MainActor
private func churnMacHosts(
  for player: Player,
  count: Int
) -> MacHostChurnResult {
  var currentHost = autoreleasepool {
    let host = MacNativePiPHostView()
    host.attach(to: player)
    return host
  }
  let originalDrawable = currentHost.drawableView
  let originalBackend = currentHost.nativePiPBackend
  let nativeHandle = player.pointer
  player.nativePlayerHasStartedPlayback = true
  var retiredHosts: [MacWeakBox<MacNativePiPHostView>] = []

  for _ in 0..<count {
    currentHost = autoreleasepool {
      replaceMacHost(
        currentHost,
        for: player,
        recording: &retiredHosts
      )
    }
  }

  return MacHostChurnResult(
    currentHost: currentHost,
    originalDrawable: originalDrawable,
    originalBackend: originalBackend,
    nativeHandle: nativeHandle,
    retiredHosts: retiredHosts
  )
}

@MainActor
private func replaceMacHost(
  _ retiredHost: MacNativePiPHostView,
  for player: Player,
  recording retiredHosts: inout [MacWeakBox<MacNativePiPHostView>]
) -> MacNativePiPHostView {
  let successorHost = MacNativePiPHostView()
  successorHost.attach(to: player)
  retiredHost.detach()
  retiredHosts.append(MacWeakBox(retiredHost))
  return successorHost
}
#endif
#endif
