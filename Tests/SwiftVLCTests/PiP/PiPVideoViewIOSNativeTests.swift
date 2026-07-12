#if os(iOS)
@testable import SwiftVLC
import CLibVLC
import CustomDump
import SwiftUI
import Testing
import UIKit

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPVideoViewIOSNativeTests {
    private func nativeDrawable(of player: Player) -> UnsafeMutableRawPointer? {
      libvlc_media_player_get_nsobject(player.pointer)
    }

    /// Pinned libVLC copies `drawable-nsobject` into
    /// `VLCVideoUIView._viewContainer` once, when the vout opens. Replacing
    /// the player's variable cannot move that already-open vout. This probe
    /// models the strong, immutable container reference so the representable
    /// lifecycle regression is deterministic without relying on decoder
    /// timing.
    @Test
    func `same-player make before dismantle reparents the vout-latched attachment`() throws {
      let player = Player(instance: TestInstance.shared)
      let originalHost = IOSNativePiPHostView()
      originalHost.attach(to: player)
      let originalAttachment = try #require(originalHost.drawableView.drawableAttachment)
      let originalBackend = originalAttachment.nativePiPBackend
      let openVout = OpenVoutContainerProbe(viewContainer: originalAttachment)
      let nativeHandle = player.pointer
      player.nativePlayerHasStartedPlayback = true

      let successorHost = IOSNativePiPHostView()
      successorHost.attach(to: player)
      originalHost.detach()

      let successorAttachment = try #require(successorHost.drawableView.drawableAttachment)
      #expect(successorAttachment === openVout.viewContainer)
      #expect(successorAttachment === originalAttachment)
      #expect(successorAttachment.superview === successorHost.drawableView)
      #expect(successorHost.nativePiPBackend === originalBackend)
      #expect(player.drawable === originalAttachment)
      #expect(nativeDrawable(of: player) == Unmanaged.passUnretained(originalAttachment).toOpaque())
      #expect(player.pointer == nativeHandle)
      #expect(originalAttachment.reserveReadyCallbackGeneration() != nil)
    }

    /// SwiftUI is also allowed to dismantle the old representable before it
    /// constructs the replacement. While a native handle has started, the
    /// exact attachment must remain installed on `Player`: that existing
    /// strong reference is the handoff lease, and avoids both a timing guess
    /// and a second Player-owned controller/session cycle.
    @Test
    func `same-player dismantle before make preserves and reparents the vout-latched attachment`() throws {
      let player = Player(instance: TestInstance.shared)
      let originalHost = IOSNativePiPHostView()
      originalHost.attach(to: player)
      let originalAttachment = try #require(originalHost.drawableView.drawableAttachment)
      let originalBackend = originalAttachment.nativePiPBackend
      let openVout = OpenVoutContainerProbe(viewContainer: originalAttachment)
      let nativeHandle = player.pointer
      player.nativePlayerHasStartedPlayback = true

      originalHost.detach()

      #expect(player.drawable === openVout.viewContainer)
      #expect(originalAttachment.superview == nil)

      let successorHost = IOSNativePiPHostView()
      successorHost.attach(to: player)
      let successorAttachment = try #require(successorHost.drawableView.drawableAttachment)

      #expect(successorAttachment === openVout.viewContainer)
      #expect(successorAttachment.superview === successorHost.drawableView)
      #expect(successorHost.nativePiPBackend === originalBackend)
      #expect(player.drawable === originalAttachment)
      #expect(nativeDrawable(of: player) == Unmanaged.passUnretained(originalAttachment).toOpaque())
      #expect(player.pointer == nativeHandle)
      #expect(originalAttachment.reserveReadyCallbackGeneration() != nil)
    }

    @Test
    func `iOS native PiP host attaches drawable child`() throws {
      let player = Player(instance: TestInstance.shared)
      let host = IOSNativePiPHostView()

      host.attach(to: player)
      let attachment = try #require(host.drawableView.drawableAttachment)
      #expect(player.drawable === attachment)

      host.detach()
      #expect(player.drawable == nil)
    }

    /// A stopped player's vout can first evaluate `pictureInPictureReady`
    /// after the host has already attached a successor player. The selector
    /// source itself therefore needs immutable attachment identity; reading
    /// the backend's current token at callback time would mis-tag the old
    /// window controller as belonging to the successor.
    @Test
    func `late old-vout ready selector cannot claim successor attachment`() throws {
      let firstPlayer = Player(instance: TestInstance.shared)
      let secondPlayer = Player(instance: TestInstance.shared)
      let view = IOSNativePiPDrawableView()

      view.attach(to: firstPlayer)
      let firstAttachment = try #require(view.drawableAttachment)

      view.attach(to: secondPlayer)
      let secondAttachment = try #require(view.drawableAttachment)

      #expect(firstAttachment !== secondAttachment)
      #expect(firstAttachment.reserveReadyCallbackGeneration() == nil)
      #expect(secondAttachment.reserveReadyCallbackGeneration() != nil)

      view.detach()
    }

    @Test
    func `attachment churn releases surfaces that have no vout`() throws {
      let player = Player(instance: TestInstance.shared)
      let view = IOSNativePiPDrawableView()
      var attachments: [WeakBox<IOSNativePiPDrawableAttachment>] = []

      try autoreleasepool {
        for _ in 0..<16 {
          view.attach(to: player)
          let attachment = try #require(view.drawableAttachment)
          attachments.append(WeakBox(attachment))
          view.detach()
        }
      }

      #expect(attachments.allSatisfy { $0.value == nil })
      #expect(player.drawable == nil)
      #expect(nativeDrawable(of: player) == nil)
      #expect(player.retainedDrawablesUntilNativePlayerRelease.isEmpty)
      withExtendedLifetime(player) {}
    }

    @Test
    func `active same-player host churn keeps one attachment and no retirement list`() throws {
      let player = Player(instance: TestInstance.shared)
      var host = IOSNativePiPHostView()
      host.attach(to: player)
      let originalAttachment = try #require(host.drawableView.drawableAttachment)
      let originalBackend = host.nativePiPBackend
      let nativeHandle = player.pointer
      player.nativePlayerHasStartedPlayback = true
      var retiredDrawableViews: [WeakBox<IOSNativePiPDrawableView>] = []

      for _ in 0..<128 {
        let retiredDrawableView = host.drawableView
        let successor = IOSNativePiPHostView()
        successor.attach(to: player)
        host.detach()
        retiredDrawableViews.append(WeakBox(retiredDrawableView))
        host = successor

        #expect(host.drawableView.drawableAttachment === originalAttachment)
        #expect(host.nativePiPBackend === originalBackend)
      }

      #expect(player.drawable === originalAttachment)
      #expect(nativeDrawable(of: player) == Unmanaged.passUnretained(originalAttachment).toOpaque())
      #expect(player.pointer == nativeHandle)
      #expect(player.retainedDrawablesUntilNativePlayerRelease.isEmpty)
      #expect(retiredDrawableViews.allSatisfy { $0.value == nil })
    }

    @Test
    func `observed externally-driven vout also leases the exact attachment`() throws {
      let player = Player(instance: TestInstance.shared)
      let originalHost = IOSNativePiPHostView()
      originalHost.attach(to: player)
      let attachment = try #require(originalHost.drawableView.drawableAttachment)
      #expect(player.nativePlayerHasStartedPlayback == false)
      player.activeVideoOutputs = 1

      originalHost.detach()

      #expect(player.drawable === attachment)
      #expect(attachment.superview == nil)

      let successorHost = IOSNativePiPHostView()
      successorHost.attach(to: player)
      #expect(successorHost.drawableView.drawableAttachment === attachment)
    }

    @Test
    func `successor policy overrides the adopted vout snapshot`() throws {
      let player = Player(instance: TestInstance.shared)
      let originalHost = IOSNativePiPHostView(startsAutomaticallyFromInline: true)
      originalHost.attach(to: player)
      let attachment = try #require(originalHost.drawableView.drawableAttachment)
      player.nativePlayerHasStartedPlayback = true
      originalHost.detach()

      let successorHost = IOSNativePiPHostView(startsAutomaticallyFromInline: false)
      successorHost.attach(to: player)
      let successorController = PiPController(
        player: player,
        nativeBackend: successorHost.nativePiPBackend,
        startsAutomaticallyFromInline: false
      )

      #expect(successorHost.drawableView.drawableAttachment === attachment)
      // The C controller may already have snapshotted this selector, so the
      // immutable attachment keeps its original answer. SwiftVLC overrides
      // the actual AVPictureInPictureController through the adopted backend.
      #expect(attachment.canStartPictureInPictureAutomaticallyFromInline())
      #expect(successorHost.nativePiPBackend.startsAutomaticallyFromInline == false)
      #expect(successorController.startsAutomaticallyFromInline == false)
    }

    @Test
    func `different-player swap gets an isolated attachment and backend`() throws {
      let firstPlayer = Player(instance: TestInstance.shared)
      let secondPlayer = Player(instance: TestInstance.shared)
      let host = IOSNativePiPHostView()
      host.attach(to: firstPlayer)
      let firstAttachment = try #require(host.drawableView.drawableAttachment)
      let firstBackend = host.nativePiPBackend
      firstPlayer.nativePlayerHasStartedPlayback = true

      host.attach(to: secondPlayer)
      let secondAttachment = try #require(host.drawableView.drawableAttachment)
      let secondBackend = host.nativePiPBackend

      #expect(firstAttachment !== secondAttachment)
      #expect(firstBackend !== secondBackend)
      #expect(firstPlayer.drawable == nil)
      #expect(secondPlayer.drawable === secondAttachment)
      #expect(firstBackend.mediaController.player == nil)
      #expect(secondBackend.mediaController.player === secondPlayer)
      #expect(firstAttachment.reserveReadyCallbackGeneration() == nil)
      #expect(secondAttachment.reserveReadyCallbackGeneration() != nil)
      #expect(firstPlayer.retainedDrawablesUntilNativePlayerRelease.count == 1)

      host.detach()
    }

    @Test
    func `detached stale host cannot repurpose an orphaned player's backend`() throws {
      let firstPlayer = Player(instance: TestInstance.shared)
      let secondPlayer = Player(instance: TestInstance.shared)
      let host = IOSNativePiPHostView()
      host.attach(to: firstPlayer)
      let firstAttachment = try #require(host.drawableView.drawableAttachment)
      let firstBackend = host.nativePiPBackend
      firstPlayer.nativePlayerHasStartedPlayback = true
      host.detach()

      host.attach(to: secondPlayer)
      let secondAttachment = try #require(host.drawableView.drawableAttachment)

      #expect(firstPlayer.drawable === firstAttachment)
      #expect(firstAttachment.nativePiPBackend === firstBackend)
      #expect(firstBackend.mediaController.player === firstPlayer)
      #expect(firstAttachment.reserveReadyCallbackGeneration() != nil)
      #expect(host.nativePiPBackend !== firstBackend)
      #expect(secondPlayer.drawable === secondAttachment)
      #expect(secondAttachment.nativePiPBackend === host.nativePiPBackend)
    }

    @Test
    func `orphaned active attachment does not retain its controller or player`() async throws {
      weak var releasedController: PiPController?
      weak var releasedPlayer: Player?

      do {
        var player: Player? = Player(instance: TestInstance.shared)
        releasedPlayer = player
        let host = IOSNativePiPHostView()
        try host.attach(to: #require(player))
        player?.nativePlayerHasStartedPlayback = true

        var controller: PiPController? = try PiPController(
          player: #require(player),
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
    func `dismantle-first successor controller claims the preserved backend`() async {
      let player = Player(instance: TestInstance.shared)
      let originalHost = IOSNativePiPHostView()
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

      let successorHost = IOSNativePiPHostView()
      successorHost.attach(to: player)
      let successorController = PiPController(
        player: player,
        nativeBackend: successorHost.nativePiPBackend
      )

      #expect(successorHost.nativePiPBackend === backend)
      #expect(backend.owner === successorController)
      withExtendedLifetime(successorController) {}
    }

    /// Regression for the exact ownerless handoff window: the drawable and
    /// native backend remain latched to the live vout, the old controller is
    /// gone, and a seekability event updates Player while no backend owner can
    /// accept it. The successor must resample Player as part of its guarded
    /// ownership claim instead of waiting for another seekability transition.
    @Test
    func `successor reconciles seekability changed during ownerless preserved attachment`() async throws {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(isSeekable: false)

      let originalHost = IOSNativePiPHostView()
      originalHost.attach(to: player)
      let attachment = try #require(originalHost.drawableView.drawableAttachment)
      let backend = originalHost.nativePiPBackend
      var originalController: PiPController? = PiPController(
        player: player,
        nativeBackend: backend
      )
      player.nativePlayerHasStartedPlayback = true

      expectNoDifference(backend.requiresLinearPlayback, true)
      #expect(backend.owner === originalController)

      originalHost.detach()
      originalController = nil
      await Task.yield()

      #expect(backend.owner == nil)
      player._handleEventForTesting(.seekableChanged(true))
      expectNoDifference(player.isSeekable, true)
      // No owner means the old linear policy is deliberately untouched.
      expectNoDifference(backend.requiresLinearPlayback, true)

      let successorHost = IOSNativePiPHostView()
      successorHost.attach(to: player)
      #expect(successorHost.drawableView.drawableAttachment === attachment)
      #expect(successorHost.nativePiPBackend === backend)

      let successorController = PiPController(
        player: player,
        nativeBackend: successorHost.nativePiPBackend
      )

      #expect(backend.owner === successorController)
      expectNoDifference(backend.requiresLinearPlayback, false)
      withExtendedLifetime(successorController) {}
    }

    @Test
    func `successor controller and binding claim the adopted backend before stale teardown`() async {
      let player = Player(instance: TestInstance.shared)
      let storage = ValueBox<PiPController?>(nil)
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: { storage.value = $0 }
      )
      let originalHost = IOSNativePiPHostView()
      originalHost.attach(to: player)
      let backend = originalHost.nativePiPBackend
      let originalCoordinator = PiPVideoView(player).makeCoordinator()
      let originalController = PiPController(player: player, nativeBackend: backend)
      originalCoordinator.pipController = originalController
      originalCoordinator.publishController(originalController, to: binding)
      await originalCoordinator.waitForControllerBindingPublication()
      player.nativePlayerHasStartedPlayback = true

      let successorHost = IOSNativePiPHostView()
      successorHost.attach(to: player)
      let successorCoordinator = PiPVideoView(player).makeCoordinator()
      let successorController = PiPController(
        player: player,
        nativeBackend: successorHost.nativePiPBackend
      )
      successorCoordinator.pipController = successorController
      successorCoordinator.publishController(successorController, to: binding)
      await successorCoordinator.waitForControllerBindingPublication()

      originalHost.detach()
      originalCoordinator.pipController = nil
      originalCoordinator.clearControllerBinding()
      await originalCoordinator.waitForControllerBindingPublication()

      #expect(successorHost.nativePiPBackend === backend)
      #expect(backend.owner === successorController)
      #expect(storage.value === successorController)
      #expect(player.drawable === successorHost.drawableView.drawableAttachment)
    }

    @Test
    func `iOS native PiP drawable exposes VLC PiP selectors`() throws {
      let player = Player(instance: TestInstance.shared)
      let view = IOSNativePiPDrawableView()
      view.attach(to: player)
      let attachment = try #require(view.drawableAttachment)

      #expect(attachment.responds(to: NSSelectorFromString("addSubview:")))
      #expect(attachment.responds(to: NSSelectorFromString("bounds")))
      #expect(attachment.responds(to: NSSelectorFromString("mediaController")))
      #expect(attachment.responds(to: NSSelectorFromString("pictureInPictureReady")))
      #expect(attachment.responds(to: NSSelectorFromString("canStartPictureInPictureAutomaticallyFromInline")))
      if let protocolObject = NSProtocolFromString("VLCPictureInPictureDrawable") {
        // Bind `conforms(to:)` to a plain Bool first. Calling it through an
        // `AnyObject` (below) inside the `#expect` autoclosure makes SILGen
        // emit a reabstraction thunk that crashes the iOS compiler (Swift
        // 6.3.2); hoisting the call out of the autoclosure sidesteps it, and
        // we keep both conformance checks consistent.
        let conformsToDrawable = attachment.conforms(to: protocolObject)
        #expect(conformsToDrawable)
      } else {
        Issue.record("VLCPictureInPictureDrawable protocol is not registered")
      }

      let mediaController = attachment.mediaController()
      if let protocolObject = NSProtocolFromString("VLCPictureInPictureMediaControlling") {
        let conformsToMediaControlling = mediaController.conforms(to: protocolObject)
        #expect(conformsToMediaControlling)
      } else {
        Issue.record("VLCPictureInPictureMediaControlling protocol is not registered")
      }
      view.detach()
    }

    /// The VLCPictureInPictureDrawable selectors are invoked by libVLC
    /// from its vout thread; their bodies are `nonisolated` and must be
    /// callable (and return correct values) off the main actor.
    @Test
    func `iOS native PiP drawable selectors are callable off the main actor`() async throws {
      let player = Player(instance: TestInstance.shared)
      let view = IOSNativePiPDrawableView(startsAutomaticallyFromInline: false)
      view.attach(to: player)
      let attachment = try #require(view.drawableAttachment)

      struct Refs: @unchecked Sendable {
        let attachment: IOSNativePiPDrawableAttachment
      }
      let refs = Refs(attachment: attachment)

      let (canStart, hasMediaController) = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Bool), Never>) in
        DispatchQueue.global().async {
          let canStart = refs.attachment.canStartPictureInPictureAutomaticallyFromInline()
          let mediaController = refs.attachment.mediaController()
          // Building the ready block off-main must also be safe; it only
          // captures a weak backend reference.
          _ = refs.attachment.pictureInPictureReady()
          continuation.resume(returning: (canStart, mediaController is IOSNativePiPMediaController))
        }
      }

      #expect(canStart == false)
      #expect(hasMediaController)
      view.detach()
    }

    @Test
    func `iOS native PiP drawable reports the configured auto-start flag`() throws {
      let enabledPlayer = Player(instance: TestInstance.shared)
      let enabledView = IOSNativePiPDrawableView(startsAutomaticallyFromInline: true)
      enabledView.attach(to: enabledPlayer)
      let enabled = try #require(enabledView.drawableAttachment)
      #expect(enabled.canStartPictureInPictureAutomaticallyFromInline() == true)

      let disabledPlayer = Player(instance: TestInstance.shared)
      let disabledView = IOSNativePiPDrawableView(startsAutomaticallyFromInline: false)
      disabledView.attach(to: disabledPlayer)
      let disabled = try #require(disabledView.drawableAttachment)
      #expect(disabled.canStartPictureInPictureAutomaticallyFromInline() == false)

      // Omitting the argument defaults to auto-start enabled.
      let defaultPlayer = Player(instance: TestInstance.shared)
      let defaultView = IOSNativePiPDrawableView()
      defaultView.attach(to: defaultPlayer)
      let defaultAttachment = try #require(defaultView.drawableAttachment)
      #expect(defaultAttachment.canStartPictureInPictureAutomaticallyFromInline() == true)

      enabledView.detach()
      disabledView.detach()
      defaultView.detach()
    }

    @Test
    func `iOS native PiP host propagates the auto-start flag to its drawable`() throws {
      let player = Player(instance: TestInstance.shared)
      let host = IOSNativePiPHostView(startsAutomaticallyFromInline: false)
      host.attach(to: player)
      let attachment = try #require(host.drawableView.drawableAttachment)
      #expect(attachment.canStartPictureInPictureAutomaticallyFromInline() == false)

      let defaultPlayer = Player(instance: TestInstance.shared)
      let defaultHost = IOSNativePiPHostView()
      defaultHost.attach(to: defaultPlayer)
      let defaultAttachment = try #require(defaultHost.drawableView.drawableAttachment)
      #expect(defaultAttachment.canStartPictureInPictureAutomaticallyFromInline() == true)

      host.detach()
      defaultHost.detach()
    }

    @Test
    func `iOS native PiP drawable sizes VLC content to its bounds`() throws {
      let player = Player(instance: TestInstance.shared)
      let view = IOSNativePiPDrawableView()
      view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
      view.attach(to: player)
      let attachment = try #require(view.drawableAttachment)
      let vlcSubview = UIView()
      attachment.addSubview(vlcSubview)
      view.layoutIfNeeded()
      attachment.layoutIfNeeded()

      #expect(vlcSubview.frame.size == CGSize(width: 640, height: 360))
      #expect(vlcSubview.autoresizingMask == [.flexibleWidth, .flexibleHeight])

      view.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
      view.layoutIfNeeded()
      attachment.layoutIfNeeded()

      #expect(vlcSubview.frame.size == CGSize(width: 480, height: 270))
      #expect(vlcSubview.autoresizingMask == [.flexibleWidth, .flexibleHeight])

      view.detach()
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

    /// libVLC's native PiP controller compares this callback result against
    /// `VLC_TICK_INVALID`, which is 0 in the pinned libVLC build. Returning
    /// libvlc's public `-1` length sentinel would instead make AVKit receive a
    /// finite negative time range for live/unknown-duration media.
    @Test
    func `iOS native PiP media controller maps unknown length to VLC tick invalid`() {
      let player = Player(instance: TestInstance.shared)
      let mediaController = IOSNativePiPMediaController()
      mediaController.player = player

      #expect(mediaController.mediaLength() == 0)
    }

    /// A ready block can outlive the drawable/player attachment that created
    /// it. Once a successor attachment starts, the old block must be unable
    /// to install its window controller or publish state into that successor.
    @Test
    func `iOS native PiP generation rejects callbacks from an old attachment`() throws {
      let generations = IOSNativePiPCallbackGenerations()
      let firstAttachment = generations.beginAttachment()
      let firstReady = try #require(
        generations.reserveReadyCallback(for: firstAttachment)
      )

      let secondAttachment = generations.beginAttachment()
      var staleMutationRan = false

      #expect(generations.reserveReadyCallback(for: firstAttachment) == nil)
      #expect(generations.reserveReadyCallback(for: secondAttachment) != nil)
      #expect(!generations.isCurrent(firstReady))
      #expect(!generations.performIfCurrent(firstReady) { staleMutationRan = true })
      #expect(!staleMutationRan)
    }

    /// libVLC may rebuild its native PiP window controller without changing
    /// players. Work queued by the previous ready callback must not overwrite
    /// state published by the replacement controller.
    @Test
    func `iOS native PiP generation keeps only the newest ready callback`() throws {
      let generations = IOSNativePiPCallbackGenerations()
      let attachment = generations.beginAttachment()
      let firstReady = try #require(
        generations.reserveReadyCallback(for: attachment)
      )
      let secondReady = try #require(
        generations.reserveReadyCallback(for: attachment)
      )
      var appliedGeneration = 0

      #expect(!generations.performIfCurrent(firstReady) { appliedGeneration = 1 })
      #expect(generations.performIfCurrent(secondReady) { appliedGeneration = 2 })
      #expect(appliedGeneration == 2)
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

    @Test
    func `active native adoption retries failed audio activation on didStart`() {
      enum ActivationFailure: Error {
        case interrupted
      }

      let player = Player(instance: TestInstance.shared)
      player.setPlaybackIntentFromExternalControl(true)
      let originalHost = IOSNativePiPHostView()
      originalHost.attach(to: player)
      let backend = originalHost.nativePiPBackend
      player.nativePlayerHasStartedPlayback = true
      originalHost.detach()

      let successorHost = IOSNativePiPHostView()
      successorHost.attach(to: player)
      #expect(successorHost.nativePiPBackend === backend)
      #expect(backend.owner == nil)

      var activationAttempts: [Int] = []
      var ownerWasInstalled: [Bool] = []

      let controller = PiPController(
        player: player,
        nativeBackend: successorHost.nativePiPBackend,
        managesAudioSession: true,
        audioSessionActivation: {
          activationAttempts.append(activationAttempts.count + 1)
          ownerWasInstalled.append(backend.owner != nil)
          if activationAttempts.count == 1 {
            throw ActivationFailure.interrupted
          }
        }
      )

      // Active intent is sampled synchronously during native construction, but
      // the failed attempt stays retryable. The first attempt precedes owner
      // publication so native auto-PiP cannot outrun it.
      expectNoDifference(activationAttempts, [1])
      expectNoDifference(ownerWasInstalled, [false])
      expectNoDifference(controller.hasActivatedAudioSession, false)

      controller.handleNativePictureInPictureActiveChanged(true)
      expectNoDifference(activationAttempts, [1, 2])
      expectNoDifference(ownerWasInstalled, [false, true])
      expectNoDifference(controller.hasActivatedAudioSession, true)

      // A later stop/start cannot repeat a successful one-shot activation.
      controller.handleNativePictureInPictureActiveChanged(false)
      controller.handleNativePictureInPictureActiveChanged(true)
      expectNoDifference(activationAttempts, [1, 2])
    }

    @Test
    func `native didStart activates when construction had no active intent`() {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      backend.attach(to: player)
      var activationAttempts = 0

      let controller = PiPController(
        player: player,
        nativeBackend: backend,
        managesAudioSession: true,
        audioSessionActivation: { activationAttempts += 1 }
      )

      expectNoDifference(activationAttempts, 0)
      expectNoDifference(controller.hasActivatedAudioSession, false)

      controller.handleNativePictureInPictureActiveChanged(true)
      expectNoDifference(activationAttempts, 1)
      expectNoDifference(controller.hasActivatedAudioSession, true)
    }

    @Test
    func `native managesAudioSession false never invokes activation policy`() {
      let player = Player(instance: TestInstance.shared)
      player.setPlaybackIntentFromExternalControl(true)
      let backend = IOSNativePiPBackend()
      backend.attach(to: player)
      var activationAttempts = 0

      let controller = PiPController(
        player: player,
        nativeBackend: backend,
        managesAudioSession: false,
        audioSessionActivation: { activationAttempts += 1 }
      )
      controller.handleNativePictureInPictureActiveChanged(true)

      expectNoDifference(activationAttempts, 0)
      expectNoDifference(controller.hasActivatedAudioSession, false)
    }

    @Test
    func `iOS native route updates linear playback and rejects retired owner`() {
      let firstPlayer = Player(instance: TestInstance.shared)
      let successorPlayer = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()

      backend.attach(to: firstPlayer)
      let firstController = PiPController(
        player: firstPlayer,
        nativeBackend: backend
      )
      firstController.applyObservedPlaybackStateUpdate(
        PiPController.PlaybackStateUpdate(
          invalidatesPlaybackState: true,
          requiresLinearPlayback: false
        )
      )
      #expect(backend.requiresLinearPlayback == false)
      #expect(backend.playbackStateInvalidationCount == 1)

      backend.detach()
      backend.attach(to: successorPlayer)
      let successor = PiPController(
        player: successorPlayer,
        nativeBackend: backend
      )
      #expect(backend.requiresLinearPlayback)
      #expect(backend.playbackStateInvalidationCount == 1)

      // A queued seekability event from the old controller must not mutate
      // the new attachment, even though both controllers share the backend.
      firstController.applyObservedPlaybackStateUpdate(
        PiPController.PlaybackStateUpdate(
          invalidatesPlaybackState: true,
          requiresLinearPlayback: false
        )
      )
      #expect(backend.requiresLinearPlayback)
      #expect(backend.playbackStateInvalidationCount == 1)

      successor.applyObservedPlaybackStateUpdate(
        PiPController.PlaybackStateUpdate(
          invalidatesPlaybackState: true,
          requiresLinearPlayback: false
        )
      )
      #expect(backend.requiresLinearPlayback == false)
      #expect(backend.playbackStateInvalidationCount == 2)

      successor.applyObservedPlaybackStateUpdate(
        PiPController.PlaybackStateUpdate(
          invalidatesPlaybackState: true,
          requiresLinearPlayback: true
        )
      )
      #expect(backend.requiresLinearPlayback)
      #expect(backend.playbackStateInvalidationCount == 3)

      backend.detach()
      withExtendedLifetime(firstController) {}
      withExtendedLifetime(successor) {}
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
  }
}

private final class WeakBox<T: AnyObject> {
  weak var value: T?

  init(_ value: T?) {
    self.value = value
  }
}

private final class ValueBox<T> {
  var value: T

  init(_ value: T) {
    self.value = value
  }
}

/// Behavioral stand-in for pinned VLCKit's ARC-strong
/// `VLCVideoUIView._viewContainer` ivar.
private final class OpenVoutContainerProbe {
  let viewContainer: IOSNativePiPDrawableAttachment

  init(viewContainer: IOSNativePiPDrawableAttachment) {
    self.viewContainer = viewContainer
  }
}
#endif
