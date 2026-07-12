#if os(iOS)
import AVFoundation
import AVKit
import CLibVLC
import os
import Synchronization
import UIKit

final class IOSNativePiPHostView: UIView {
  let drawableView: IOSNativePiPDrawableView

  var nativePiPBackend: IOSNativePiPBackend {
    drawableView.nativePiPBackend
  }

  init(startsAutomaticallyFromInline: Bool = true) {
    drawableView = IOSNativePiPDrawableView(
      startsAutomaticallyFromInline: startsAutomaticallyFromInline
    )
    super.init(frame: .zero)
    backgroundColor = .black
    clipsToBounds = true

    nativePiPBackend.hostView = self
    drawableView.frame = bounds
    drawableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(drawableView)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func attach(to player: Player) {
    drawableView.attach(to: player)
    nativePiPBackend.hostView = self
  }

  func detach() {
    drawableView.detach()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    drawableView.frame = bounds
  }
}

typealias IOSNativePictureInPictureReadyBlock = @convention(block) (AnyObject) -> Void
typealias IOSNativePiPStateChangeEventHandler = @convention(block) (Bool) -> Void

/// Thread-safe identity for work originating in libVLC's native PiP
/// callbacks. The drawable callbacks arrive off-main and can remain queued
/// while the SwiftUI view detaches, reattaches, or receives a replacement
/// native window controller.
final class IOSNativePiPCallbackGenerations: Sendable {
  struct Attachment: Equatable {
    fileprivate let rawValue: UInt64
  }

  struct ReadyCallback: Equatable {
    fileprivate let attachment: Attachment
    fileprivate let rawValue: UInt64
  }

  private struct State {
    var nextAttachment: UInt64 = 0
    var currentAttachment: Attachment?
    var nextReadyCallback: UInt64 = 0
    var currentReadyCallback: ReadyCallback?
  }

  private let state = Mutex(State())

  @MainActor
  func beginAttachment() -> Attachment {
    state.withLock { state in
      state.nextAttachment &+= 1
      let attachment = Attachment(rawValue: state.nextAttachment)
      state.currentAttachment = attachment
      state.currentReadyCallback = nil
      return attachment
    }
  }

  @MainActor
  func invalidateAttachment() {
    state.withLock { state in
      state.currentAttachment = nil
      state.currentReadyCallback = nil
    }
  }

  @MainActor
  func currentAttachment() -> Attachment? {
    state.withLock { $0.currentAttachment }
  }

  @MainActor
  func reserveReadyCallback(for attachment: Attachment) -> ReadyCallback? {
    state.withLock { state in
      guard state.currentAttachment == attachment else { return nil }
      state.nextReadyCallback &+= 1
      let callback = ReadyCallback(
        attachment: attachment,
        rawValue: state.nextReadyCallback
      )
      state.currentReadyCallback = callback
      return callback
    }
  }

  @MainActor
  func isCurrent(_ callback: ReadyCallback) -> Bool {
    state.withLock {
      $0.currentAttachment == callback.attachment
        && $0.currentReadyCallback == callback
    }
  }

  /// Applies UI state only for the currently selected callback. Both callback
  /// reservation and this check/action are main-actor isolated, so a newer
  /// ready callback cannot invalidate the generation between the check and
  /// UIKit/KVO mutation. The mutex remains for attachment invalidation reads
  /// originating in diagnostic/test code; it is never held across UI work.
  @MainActor
  @discardableResult
  func performIfCurrent(
    _ callback: ReadyCallback,
    _ action: @MainActor () -> Void
  ) -> Bool {
    guard isCurrent(callback) else { return false }
    action()
    return true
  }
}

@objc(VLCPictureInPictureDrawable)
private protocol IOSNativePiPDrawable: NSObjectProtocol {
  @objc(mediaController)
  func mediaController() -> AnyObject

  @objc(pictureInPictureReady)
  func pictureInPictureReady() -> IOSNativePictureInPictureReadyBlock

  @objc(canStartPictureInPictureAutomaticallyFromInline)
  optional func canStartPictureInPictureAutomaticallyFromInline() -> Bool
}

@objc(VLCPictureInPictureMediaControlling)
private protocol IOSNativePiPMediaControlling: NSObjectProtocol {
  @objc func play()
  @objc func pause()

  @objc(seekBy:completion:)
  func seek(by offset: Int64, completion: (() -> Void)?)

  @objc func mediaLength() -> Int64
  @objc func mediaTime() -> Int64
  @objc func isMediaSeekable() -> Bool
  @objc func isMediaPlaying() -> Bool
}

/// The `UIView` libVLC renders into for one callback generation. It owns that
/// generation's `attachment` and bridges the `@objc` hooks — media controller,
/// PiP-ready block, and auto-start policy — that AVKit's inline PiP path calls.
@MainActor
final class IOSNativePiPDrawableAttachment: UIView, IOSNativePiPDrawable {
  nonisolated let attachment: IOSNativePiPCallbackGenerations.Attachment
  nonisolated let nativeMediaController: IOSNativePiPMediaController
  nonisolated let startsAutomaticallyFromInline: Bool
  nonisolated let nativePiPBackend: IOSNativePiPBackend

  init(
    nativePiPBackend: IOSNativePiPBackend,
    attachment: IOSNativePiPCallbackGenerations.Attachment,
    mediaController: IOSNativePiPMediaController,
    startsAutomaticallyFromInline: Bool
  ) {
    self.nativePiPBackend = nativePiPBackend
    self.attachment = attachment
    nativeMediaController = mediaController
    self.startsAutomaticallyFromInline = startsAutomaticallyFromInline
    super.init(frame: .zero)
    backgroundColor = .black
    clipsToBounds = true
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    resizeRenderingChildren()
  }

  override func didAddSubview(_ subview: UIView) {
    super.didAddSubview(subview)
    resizeRenderingSubview(subview)
  }

  override func layoutSublayers(of layer: CALayer) {
    super.layoutSublayers(of: layer)
    guard layer === self.layer else { return }
    resizeRenderingLayers()
  }

  @objc(mediaController)
  nonisolated func mediaController() -> AnyObject {
    nativeMediaController
  }

  func reserveReadyCallbackGeneration()
    -> IOSNativePiPCallbackGenerations.ReadyCallback? {
    nativePiPBackend.callbackGenerations.reserveReadyCallback(for: attachment)
  }

  @objc(pictureInPictureReady)
  nonisolated func pictureInPictureReady() -> IOSNativePictureInPictureReadyBlock {
    let attachment = attachment
    return { [weak nativePiPBackend] windowController in
      nonisolated(unsafe) let windowController = windowController
      Task { @MainActor in
        guard
          let nativePiPBackend,
          let generation = nativePiPBackend.callbackGenerations.reserveReadyCallback(
            for: attachment
          )
        else { return }
        nativePiPBackend.handlePictureInPictureReady(
          windowController,
          generation: generation
        )
      }
    }
  }

  @objc(canStartPictureInPictureAutomaticallyFromInline)
  nonisolated func canStartPictureInPictureAutomaticallyFromInline() -> Bool {
    startsAutomaticallyFromInline
  }

  private var hasDrawableBounds: Bool {
    bounds.width > 0 && bounds.height > 0
  }

  private func resizeRenderingChildren() {
    guard hasDrawableBounds else { return }
    subviews.forEach(resizeRenderingSubview)
    resizeRenderingLayers()
  }

  private func resizeRenderingSubview(_ subview: UIView) {
    guard hasDrawableBounds else { return }
    subview.frame = bounds
    subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    syncContentScale(to: subview)
    subview.setNeedsLayout()
    subview.layoutIfNeeded()
    reshapeVLCSubviewIfNeeded(subview)
  }

  private func resizeRenderingLayers() {
    guard hasDrawableBounds else { return }
    layer.sublayers?.forEach { sublayer in
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      sublayer.frame = bounds
      CATransaction.commit()
    }
  }

  private func syncContentScale(to subview: UIView) {
    let scale = window?.screen.scale
      ?? subview.window?.screen.scale
      ?? UIScreen.main.scale
    subview.contentScaleFactor = scale
    subview.layer.contentsScale = scale
  }
}

@MainActor
final class IOSNativePiPDrawableView: UIView {
  private(set) var nativePiPBackend = IOSNativePiPBackend()

  /// Answer copied into each attachment proxy for libVLC's off-main
  /// auto-PiP probe.
  let startsAutomaticallyFromInline: Bool

  private weak var attachedPlayer: Player?
  /// The active attachment is owned here and by `Player`. A retiring vout
  /// remains safe without a host-level retirement list: pinned libVLC's
  /// ARC-built `VLCVideoUIView` holds its drawable in strong `_viewContainer`
  /// storage until that vout closes. With no vout there can be no late PiP
  /// selector, so keeping every swapped attachment would only leak surfaces.
  private(set) var drawableAttachment: IOSNativePiPDrawableAttachment?

  init(startsAutomaticallyFromInline: Bool = true) {
    self.startsAutomaticallyFromInline = startsAutomaticallyFromInline
    super.init(frame: .zero)
    backgroundColor = .black
    clipsToBounds = true
    nativePiPBackend.drawableView = self
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func attach(to player: Player) {
    if let attachedPlayer, attachedPlayer !== player {
      detachCompletely(from: attachedPlayer)
      installFreshBackend()
    }

    // Pinned libVLC copies `drawable-nsobject` into a strong
    // `VLCVideoUIView._viewContainer` exactly once at vout open. Updating the
    // player variable to a new UIView cannot redirect that live vout. During
    // a same-player SwiftUI recreation the existing Player-held attachment
    // is therefore the lease: adopt and reparent that exact object together
    // with its native backend instead of manufacturing a successor surface.
    if !adoptCurrentAttachment(from: player) {
      if
        attachedPlayer != nil
        || drawableAttachment != nil
        || nativePiPBackend.mediaController.player != nil {
        abandonLocalReferences()
        installFreshBackend()
      }
      makeAttachment(for: player)
    }

    player.claimDrawableOwnership(self)
    publishDrawableIfReady()
  }

  func detach() {
    guard let player = attachedPlayer else { return }

    // A successor host may already have adopted this exact attachment. Its
    // claim wins; stale dismantle must not remove the reparented view or tear
    // down the shared backend/controller wiring.
    guard player.isDrawableOwner(self) else {
      abandonLocalReferences()
      return
    }

    if mustPreserveAttachment(for: player) {
      // Leave `Player.drawable` untouched. It is already the strong O(1)
      // lease required by both possible SwiftUI lifecycle orderings, and it
      // is retained/released with the exact native handle. Keeping only the
      // active attachment also avoids a Player -> PiPController cycle: the
      // backend owner and media-controller player links remain weak.
      player.releaseDrawableOwnership(self)
      abandonLocalReferences()
      return
    }

    // No SwiftVLC- or list-player-driven playback has started, no live native
    // state is reported, and no vout is observed. Nothing can have latched
    // this attachment, so ordinary view churn releases it immediately.
    detachCompletely(from: player)
    installFreshBackend()
  }

  private func mustPreserveAttachment(for player: Player) -> Bool {
    if
      player.nativePlayerHasStartedPlayback
      || player.nativePlayerNeedsReplacementBeforePlayback
      || player.attachedMediaListPlayer != nil
      || player.activeVideoOutputs > 0 {
      return true
    }

    // A MediaListPlayer (or another in-module native driver) starts the same
    // libVLC media-player handle without entering `Player.play()`, so the
    // direct-path `nativePlayerHasStartedPlayback` bit is not sufficient.
    // The live native state closes that gap before the mirrored vout count or
    // observable state reaches the main actor.
    switch player.nativePlaybackState {
    case .idle, .stopped, .error:
      return false
    case .opening, .buffering, .playing, .paused, .stopping:
      return true
    }
  }

  private func adoptCurrentAttachment(from player: Player) -> Bool {
    guard
      let attachment = player.drawable as? IOSNativePiPDrawableAttachment,
      attachment.nativePiPBackend.mediaController.player === player,
      attachment.nativePiPBackend.callbackGenerations.currentAttachment()
      == attachment.attachment
    else { return false }

    let backend = attachment.nativePiPBackend
    nativePiPBackend = backend
    backend.drawableView = self
    if let hostView = superview as? IOSNativePiPHostView {
      backend.hostView = hostView
    }
    attachedPlayer = player
    drawableAttachment = attachment
    // The pinned native PiP controller snapshots this selector at vout open.
    // Preserve that original policy with the exact attachment/backend; merely
    // changing the proxy's answer here would not reconfigure the live native
    // controller and would make Swift state disagree with system behavior.
    reparent(attachment)
    return true
  }

  private func makeAttachment(for player: Player) {
    attachedPlayer = player
    nativePiPBackend.drawableView = self
    if let hostView = superview as? IOSNativePiPHostView {
      nativePiPBackend.hostView = hostView
    }
    let attachment = nativePiPBackend.attach(to: player)
    let drawableAttachment = IOSNativePiPDrawableAttachment(
      nativePiPBackend: nativePiPBackend,
      attachment: attachment,
      mediaController: nativePiPBackend.mediaController,
      startsAutomaticallyFromInline: startsAutomaticallyFromInline
    )
    self.drawableAttachment = drawableAttachment
    reparent(drawableAttachment)
  }

  private func reparent(_ attachment: IOSNativePiPDrawableAttachment) {
    if attachment.superview !== self {
      attachment.removeFromSuperview()
      addSubview(attachment)
    }
    attachment.frame = bounds
    attachment.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    attachment.setNeedsLayout()
  }

  private func detachCompletely(from player: Player) {
    guard player.isDrawableOwner(self) else {
      abandonLocalReferences()
      return
    }

    player.releaseDrawableOwnership(self)
    if let drawableAttachment {
      player.clearDrawable(ifCurrent: drawableAttachment)
      if drawableAttachment.superview === self {
        drawableAttachment.removeFromSuperview()
      }
    }
    nativePiPBackend.detach()
    abandonLocalReferences()
  }

  private func abandonLocalReferences() {
    if let drawableAttachment, drawableAttachment.superview === self {
      drawableAttachment.removeFromSuperview()
    }
    drawableAttachment = nil
    attachedPlayer = nil
  }

  private func installFreshBackend() {
    let backend = IOSNativePiPBackend()
    backend.drawableView = self
    if let hostView = superview as? IOSNativePiPHostView {
      backend.hostView = hostView
    }
    nativePiPBackend = backend
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    guard hasDrawableBounds else { return }

    publishDrawableIfReady()
    resizeRenderingChildren()
  }

  override func didAddSubview(_ subview: UIView) {
    super.didAddSubview(subview)
    resizeRenderingSubview(subview)
  }

  override func layoutSublayers(of layer: CALayer) {
    super.layoutSublayers(of: layer)
    guard layer === self.layer else { return }
    resizeRenderingLayers()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      publishDrawableIfReady()
      setNeedsLayout()
      layer.setNeedsLayout()
    }
  }

  private var hasDrawableBounds: Bool {
    bounds.width > 0 && bounds.height > 0
  }

  private func publishDrawableIfReady() {
    guard
      let player = attachedPlayer,
      let drawableAttachment,
      player.isDrawableOwner(self)
    else { return }
    if !player.isCurrentDrawable(drawableAttachment) {
      player.setDrawable(drawableAttachment, owner: self)
      resizeRenderingChildren()
    }
  }

  private func resizeRenderingChildren() {
    guard hasDrawableBounds else { return }
    subviews.forEach(resizeRenderingSubview)
    resizeRenderingLayers()
  }

  private func resizeRenderingSubview(_ subview: UIView) {
    guard hasDrawableBounds else { return }
    subview.frame = bounds
    subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    syncContentScale(to: subview)
    subview.setNeedsLayout()
    subview.layoutIfNeeded()
    reshapeVLCSubviewIfNeeded(subview)
  }

  private func resizeRenderingLayers() {
    guard hasDrawableBounds else { return }
    layer.sublayers?.forEach { sublayer in
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      sublayer.frame = bounds
      CATransaction.commit()
    }
  }

  private func syncContentScale(to subview: UIView) {
    let scale = window?.screen.scale
      ?? subview.window?.screen.scale
      ?? UIScreen.main.scale
    subview.contentScaleFactor = scale
    subview.layer.contentsScale = scale
  }
}

@MainActor
final class IOSNativePiPBackend: NSObject, @unchecked Sendable {
  private(set) var mediaController = IOSNativePiPMediaController()
  nonisolated let callbackGenerations = IOSNativePiPCallbackGenerations()
  weak var owner: PiPController? {
    didSet {
      mediaController.owner = owner
      if
        let owner,
        mediaController.player === owner.player,
        let attachment = callbackGenerations.currentAttachment() {
        ownerAttachment = attachment
      } else {
        ownerAttachment = nil
      }
    }
  }

  /// Exact attachment generation claimed by ``owner``. A non-nil current
  /// generation alone is not enough: after detach/reattach, an old owner must
  /// not be treated as owning whichever generation happens to be current.
  private var ownerAttachment: IOSNativePiPCallbackGenerations.Attachment?

  weak var hostView: IOSNativePiPHostView?
  weak var drawableView: IOSNativePiPDrawableView?

  private static var supportsNativePictureInPictureRendering: Bool {
    #if targetEnvironment(simulator)
    // The system can report active sample-buffer PiP while rendering a black window.
    false
    #else
    true
    #endif
  }

  private weak var windowController: NSObject?
  private var avPictureInPictureController: AVPictureInPictureController?
  private var possibleObservation: NSKeyValueObservation?
  private var activeObservation: NSKeyValueObservation?
  private var stateChangeEventHandler: IOSNativePiPStateChangeEventHandler?

  private(set) var isPossible = false
  private(set) var isActive = false
  private(set) var requiresLinearPlayback = true
  private(set) var startsAutomaticallyFromInline = true
  private(set) var playbackStateInvalidationCount: UInt64 = 0
  private var didWarnAboutVideoOutput = false

  private static let logger = Logger(
    subsystem: Signposts.subsystem,
    category: "PictureInPicture"
  )

  @discardableResult
  func attach(to player: Player) -> IOSNativePiPCallbackGenerations.Attachment {
    let attachment = callbackGenerations.beginAttachment()
    let mediaController = IOSNativePiPMediaController()
    mediaController.player = player
    mediaController.owner = owner?.player === player ? owner : nil
    self.mediaController = mediaController
    ownerAttachment = mediaController.owner == nil ? nil : attachment
    requiresLinearPlayback = !player.isSeekable
    setPossible(false)
    setActive(false)
    return attachment
  }

  func detach() {
    // Invalidate before stopping the old controller: stop/KVO callbacks can
    // be delivered synchronously or remain queued after teardown.
    callbackGenerations.invalidateAttachment()
    stop()
    clearWindowController()
    mediaController.player = nil
    mediaController.owner = nil
    ownerAttachment = nil
    setPossible(false)
    setActive(false)
  }

  func handlePictureInPictureReady(_ controller: AnyObject) {
    guard
      let attachment = callbackGenerations.currentAttachment(),
      let generation = callbackGenerations.reserveReadyCallback(for: attachment)
    else { return }
    handlePictureInPictureReady(controller, generation: generation)
  }

  func handlePictureInPictureReady(
    _ controller: AnyObject,
    generation: IOSNativePiPCallbackGenerations.ReadyCallback
  ) {
    guard let controller = controller as? NSObject else { return }

    callbackGenerations.performIfCurrent(generation) {
      clearWindowController()
      guard Self.supportsNativePictureInPictureRendering else {
        setPossible(false)
        setActive(false)
        return
      }

      windowController = controller
      installStateChangeHandler(on: controller, generation: generation)
      observeAVPictureInPictureController(on: controller, generation: generation)

      if avPictureInPictureController == nil {
        setPossible(true)
      }
    }
  }

  func start() {
    guard isPossible, mediaController.player?.currentMedia != nil else {
      warnIfVideoOutputBlocksPictureInPicture()
      return
    }
    performWindowControllerAction(IOSNativePiPSelector.start)
  }

  /// One-time diagnostic for the common misconfiguration where a custom
  /// ``VLCInstance`` forces a non-default video output (e.g. `--vout=gles2`
  /// or `--no-video`): libVLC then never selects the sample-buffer display
  /// PiP needs, the PiP-ready callback never fires, and ``isPossible``
  /// stays `false` with no other signal.
  private func warnIfVideoOutputBlocksPictureInPicture() {
    guard !didWarnAboutVideoOutput else { return }
    guard
      let instance = mediaController.player?.instance,
      !instance.usesPiPSafeDarwinDisplay
    else { return }
    didWarnAboutVideoOutput = true
    Self.logger.warning(
      """
      Picture in Picture is unavailable: this VLCInstance's video-output \
      arguments (e.g. --vout or --no-video) stop libVLC from selecting the \
      sample-buffer display that native PiP requires. Use the default video \
      output to enable PiP.
      """
    )
  }

  func stop() {
    performWindowControllerAction(IOSNativePiPSelector.stop)
  }

  func invalidatePlaybackState() {
    playbackStateInvalidationCount &+= 1
    performWindowControllerAction(IOSNativePiPSelector.invalidatePlaybackState)
  }

  func setStartsAutomaticallyFromInline(_ enabled: Bool) {
    startsAutomaticallyFromInline = enabled
    avPictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = enabled
  }

  func invalidatePlaybackState(ifOwnedBy expectedOwner: PiPController) {
    guard ownsCurrentAttachment(expectedOwner) else { return }
    invalidatePlaybackState()
  }

  /// Updates AVKit's transport policy only for the controller that owns the
  /// current attachment. A retired controller can still drain a queued player
  /// event after a swap; these checks keep it from mutating the successor.
  func setRequiresLinearPlayback(
    _ requiresLinearPlayback: Bool,
    ifOwnedBy expectedOwner: PiPController
  ) {
    guard ownsCurrentAttachment(expectedOwner) else { return }

    self.requiresLinearPlayback = requiresLinearPlayback
    avPictureInPictureController?.requiresLinearPlayback = requiresLinearPlayback
  }

  /// Re-samples the current attachment's player when a controller claims an
  /// existing native backend. Both owner identity and the live attachment
  /// generation are checked before mutation, so neither a retired controller
  /// nor a controller constructed before attachment can change AVKit policy.
  func reconcileRequiresLinearPlayback(ifOwnedBy expectedOwner: PiPController) {
    guard ownsCurrentAttachment(expectedOwner) else { return }

    let requiresLinearPlayback = !expectedOwner.player.isSeekable
    self.requiresLinearPlayback = requiresLinearPlayback
    avPictureInPictureController?.requiresLinearPlayback = requiresLinearPlayback
  }

  private func ownsCurrentAttachment(_ expectedOwner: PiPController) -> Bool {
    owner === expectedOwner
      && mediaController.player === expectedOwner.player
      && ownerAttachment == callbackGenerations.currentAttachment()
      && ownerAttachment != nil
  }

  private func clearWindowController() {
    if
      let windowController,
      windowController.responds(to: IOSNativePiPSelector.setStateChangeEventHandler) {
      windowController.setValue(nil, forKey: "stateChangeEventHandler")
    }
    possibleObservation = nil
    activeObservation = nil
    avPictureInPictureController = nil
    stateChangeEventHandler = nil
    windowController = nil
  }

  private func installStateChangeHandler(
    on controller: NSObject,
    generation: IOSNativePiPCallbackGenerations.ReadyCallback
  ) {
    guard controller.responds(to: IOSNativePiPSelector.setStateChangeEventHandler) else { return }

    let handler: IOSNativePiPStateChangeEventHandler = { [weak self] isStarted in
      Task { @MainActor in
        guard let self else { return }
        self.callbackGenerations.performIfCurrent(generation) {
          self.setActive(isStarted)
        }
      }
    }
    stateChangeEventHandler = handler
    controller.setValue(handler, forKey: "stateChangeEventHandler")
  }

  private func observeAVPictureInPictureController(
    on controller: NSObject,
    generation: IOSNativePiPCallbackGenerations.ReadyCallback
  ) {
    guard controller.responds(to: IOSNativePiPSelector.avPictureInPictureController) else { return }
    guard let avController = controller.value(forKey: "avPipController") as? AVPictureInPictureController else { return }

    avPictureInPictureController = avController
    avController.requiresLinearPlayback = requiresLinearPlayback
    avController.canStartPictureInPictureAutomaticallyFromInline =
      startsAutomaticallyFromInline
    setPossible(avController.isPictureInPicturePossible)
    setActive(avController.isPictureInPictureActive)

    possibleObservation = avController.observe(
      \.isPictureInPicturePossible,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
      let isPossible = controller.isPictureInPicturePossible
      Task { @MainActor [weak self] in
        guard let self else { return }
        callbackGenerations.performIfCurrent(generation) {
          self.setPossible(isPossible)
        }
      }
    }

    activeObservation = avController.observe(
      \.isPictureInPictureActive,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
      let isActive = controller.isPictureInPictureActive
      Task { @MainActor [weak self] in
        guard let self else { return }
        callbackGenerations.performIfCurrent(generation) {
          self.setActive(isActive)
        }
      }
    }
  }

  private func performWindowControllerAction(_ selector: Selector) {
    guard let windowController, windowController.responds(to: selector) else { return }
    _ = windowController.perform(selector)
  }

  func makeValidationProbe() -> NativePiPProbe {
    let delegateSelectorNames = [
      "pictureInPictureControllerWillStartPictureInPicture:",
      "pictureInPictureControllerDidStartPictureInPicture:",
      "pictureInPictureControllerDidStopPictureInPicture:",
      "pictureInPictureController:failedToStartPictureInPictureWithError:",
      "pictureInPictureController:restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:"
    ]

    let delegate = avPictureInPictureController?.delegate
    var delegateResponds: [String: Bool] = [:]
    if let delegate {
      for name in delegateSelectorNames {
        delegateResponds[name] = delegate.responds(to: Selector((name)))
      }
    }

    return NativePiPProbe(
      windowControllerClassName: windowController.map { NSStringFromClass(type(of: $0)) },
      hasAVController: avPictureInPictureController != nil,
      avDelegateClassName: delegate.flatMap { object_getClass($0) }.map { NSStringFromClass($0) },
      delegateResponds: delegateResponds,
      isPossible: isPossible,
      isActive: isActive
    )
  }

  private func setPossible(_ isPossible: Bool) {
    guard self.isPossible != isPossible else { return }
    self.isPossible = isPossible
    owner?.handleNativePictureInPictureReady()
  }

  private func setActive(_ isActive: Bool) {
    guard self.isActive != isActive else { return }
    self.isActive = isActive
    owner?.handleNativePictureInPictureActiveChanged(isActive)
  }
}

final class IOSNativePiPMediaController: NSObject, IOSNativePiPMediaControlling, @unchecked Sendable {
  weak var player: Player?
  weak var owner: PiPController?

  @objc func play() {
    Task { @MainActor [weak self] in
      guard let self, let player else { return }
      // A cold start after playback ended is not a resume — begin afresh.
      if player.state == .idle || player.state == .stopped {
        try? player.play()
        return
      }
      // Otherwise route through the controller so the AVKit-transient pause
      // debouncer and PiP playback-state reconciliation engage. Fall back to
      // a direct resume when constructed without a controller (the public
      // direct-`PiPController` usage path).
      if let owner {
        owner.handleNativePictureInPictureSetPlaying(true)
      } else {
        player.resume()
      }
    }
  }

  @objc func pause() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let owner {
        owner.handleNativePictureInPictureSetPlaying(false)
      } else {
        player?.pause()
      }
    }
  }

  @objc(seekBy:completion:)
  func seek(by offset: Int64, completion: (() -> Void)?) {
    nonisolated(unsafe) let completion = completion
    Task { @MainActor [weak self] in
      guard let player = self?.player else {
        completion?()
        return
      }

      let target = PiPController.clampedSkipTargetMilliseconds(
        current: player.currentTime.milliseconds,
        offset: offset,
        duration: player.duration?.milliseconds
      )
      try? player.seek(to: .milliseconds(target))
      completion?()
    }
  }

  @objc func mediaLength() -> Int64 {
    pipMainActorSync { [weak self] in
      guard let player = self?.player else { return 0 }
      let length = libvlc_media_player_get_length(player.pointer)
      // VLC's native PiP module checks for VLC_TICK_INVALID (0), not
      // libvlc's public unknown-length sentinel (-1).
      return length > 0 ? length : 0
    }
  }

  @objc func mediaTime() -> Int64 {
    pipMainActorSync { [weak self] in
      guard let player = self?.player else { return 0 }
      return max(libvlc_media_player_get_time(player.pointer), 0)
    }
  }

  @objc func isMediaSeekable() -> Bool {
    pipMainActorSync { [weak self] in
      guard let player = self?.player else { return false }
      return libvlc_media_player_is_seekable(player.pointer)
    }
  }

  @objc func isMediaPlaying() -> Bool {
    pipMainActorSync { [weak self] in
      guard let player = self?.player else { return false }
      return player.isPlaybackRequestedActive
    }
  }
}

private enum IOSNativePiPSelector {
  static let start = NSSelectorFromString("startPictureInPicture")
  static let stop = NSSelectorFromString("stopPictureInPicture")
  static let invalidatePlaybackState = NSSelectorFromString("invalidatePlaybackState")
  static let setStateChangeEventHandler = NSSelectorFromString("setStateChangeEventHandler:")
  static let avPictureInPictureController = NSSelectorFromString("avPipController")
}

private let vlcUIViewReshapeSelector = NSSelectorFromString("reshape")

@MainActor
private func reshapeVLCSubviewIfNeeded(_ subview: UIView) {
  guard
    subview.responds(to: vlcUIViewReshapeSelector),
    subview.bounds.width > 0,
    subview.bounds.height > 0
  else { return }
  _ = subview.perform(vlcUIViewReshapeSelector)
}

#endif
