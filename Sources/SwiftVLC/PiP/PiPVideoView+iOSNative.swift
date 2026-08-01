// swiftlint:disable file_length
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
  struct Attachment: Equatable, Sendable {
    fileprivate let rawValue: UInt64
  }

  struct ReadyCallback: Equatable, Sendable {
    fileprivate let attachment: Attachment
    fileprivate let rawValue: UInt64
  }

  /// Provenance captured when an explicit start reaches one exact native
  /// window controller. Native active signals snapshot this value before
  /// hopping to the main actor, so a later media load or accepted start cannot
  /// relabel the signal that was already delivered.
  struct AcceptedStart: Equatable, Sendable {
    fileprivate let callback: ReadyCallback
    let mediaGeneration: PlaybackGeneration
  }

  private struct State {
    var nextAttachment: UInt64 = 0
    var currentAttachment: Attachment?
    var nextReadyCallback: UInt64 = 0
    var currentReadyCallback: ReadyCallback?
    var acceptedStart: AcceptedStart?
  }

  private let state = Mutex(State())

  @MainActor
  func beginAttachment() -> Attachment {
    state.withLock { state in
      state.nextAttachment &+= 1
      let attachment = Attachment(rawValue: state.nextAttachment)
      state.currentAttachment = attachment
      state.currentReadyCallback = nil
      state.acceptedStart = nil
      return attachment
    }
  }

  @MainActor
  func invalidateAttachment() {
    state.withLock { state in
      state.currentAttachment = nil
      state.currentReadyCallback = nil
      state.acceptedStart = nil
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
      state.acceptedStart = nil
      return callback
    }
  }

  @MainActor
  @discardableResult
  func recordAcceptedStart(mediaGeneration: PlaybackGeneration) -> Bool {
    state.withLock { state in
      guard let callback = state.currentReadyCallback else { return false }
      state.acceptedStart = AcceptedStart(
        callback: callback,
        mediaGeneration: mediaGeneration
      )
      return true
    }
  }

  nonisolated func acceptedStart(
    at callback: ReadyCallback
  ) -> AcceptedStart? {
    state.withLock { state in
      guard
        state.currentAttachment == callback.attachment,
        state.currentReadyCallback == callback,
        state.acceptedStart?.callback == callback
      else { return nil }
      return state.acceptedStart
    }
  }

  @MainActor
  func currentAcceptedStart() -> AcceptedStart? {
    state.withLock { state in
      guard
        let callback = state.currentReadyCallback,
        state.acceptedStart?.callback == callback
      else { return nil }
      return state.acceptedStart
    }
  }

  @MainActor
  func clearAcceptedStart() {
    state.withLock { $0.acceptedStart = nil }
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
    let nativeMediaController = nativeMediaController
    return { [weak nativePiPBackend] windowController in
      let mediaGeneration = nativeMediaController.callbackSnapshot.withLock {
        $0.playbackGeneration
      }
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
          generation: generation,
          mediaGeneration: mediaGeneration
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
  private(set) var activeMediaGeneration: PlaybackGeneration?
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
    let mediaGeneration = mediaController.callbackSnapshot.withLock {
      $0.playbackGeneration
    }
    handlePictureInPictureReady(
      controller,
      generation: generation,
      mediaGeneration: mediaGeneration
    )
  }

  func handlePictureInPictureReady(
    _ controller: AnyObject,
    generation: IOSNativePiPCallbackGenerations.ReadyCallback,
    mediaGeneration: PlaybackGeneration?
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
      observeAVPictureInPictureController(
        on: controller,
        generation: generation,
        initialActiveMediaGeneration: mediaGeneration
      )

      if avPictureInPictureController == nil {
        setPossible(true)
      }
    }
  }

  func start() -> PiPStartResult {
    guard mediaController.player?.currentMedia != nil else {
      warnIfVideoOutputBlocksPictureInPicture()
      return .noMedia
    }
    guard isPossible else {
      warnIfVideoOutputBlocksPictureInPicture()
      return .notPossible
    }
    guard
      let windowController,
      windowController.responds(to: IOSNativePiPSelector.start)
    else { return .backendUnavailable }

    // Record before invoking the native selector. Its active callback may be
    // synchronous, and that callback must be able to snapshot the request it
    // is acknowledging. A repeated start while already active does not begin
    // a new lifecycle and must not seed provenance for a future one.
    if !isActive, let mediaGeneration = mediaController.player?.generation {
      callbackGenerations.recordAcceptedStart(
        mediaGeneration: mediaGeneration
      )
    }
    _ = windowController.perform(IOSNativePiPSelector.start)
    return .accepted
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
    callbackGenerations.clearAcceptedStart()
    windowController = nil
  }

  private func installStateChangeHandler(
    on controller: NSObject,
    generation: IOSNativePiPCallbackGenerations.ReadyCallback
  ) {
    guard controller.responds(to: IOSNativePiPSelector.setStateChangeEventHandler) else { return }

    let mediaController = mediaController
    let callbackGenerations = callbackGenerations
    let handler: IOSNativePiPStateChangeEventHandler = { [weak self] isStarted in
      let mediaGeneration = isStarted
        ? mediaController.callbackSnapshot.withLock { $0.playbackGeneration }
        : nil
      let acceptedStart = isStarted
        ? callbackGenerations.acceptedStart(at: generation)
        : nil
      Task { @MainActor in
        guard let self else { return }
        self.callbackGenerations.performIfCurrent(generation) {
          self.setActiveFromNativeSignal(
            isStarted,
            mediaGeneration: mediaGeneration,
            acceptedStart: acceptedStart
          )
        }
      }
    }
    stateChangeEventHandler = handler
    controller.setValue(handler, forKey: "stateChangeEventHandler")
  }

  private func observeAVPictureInPictureController(
    on controller: NSObject,
    generation: IOSNativePiPCallbackGenerations.ReadyCallback,
    initialActiveMediaGeneration: PlaybackGeneration?
  ) {
    guard controller.responds(to: IOSNativePiPSelector.avPictureInPictureController) else { return }
    guard let avController = controller.value(forKey: "avPipController") as? AVPictureInPictureController else { return }

    avPictureInPictureController = avController
    avController.requiresLinearPlayback = requiresLinearPlayback
    avController.canStartPictureInPictureAutomaticallyFromInline =
      startsAutomaticallyFromInline
    setPossible(avController.isPictureInPicturePossible)
    setActiveFromNativeSignal(
      avController.isPictureInPictureActive,
      mediaGeneration: initialActiveMediaGeneration,
      acceptedStart: nil
    )

    let callbackGenerations = callbackGenerations
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

    let mediaController = mediaController
    activeObservation = avController.observe(
      \.isPictureInPictureActive,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
      let isActive = controller.isPictureInPictureActive
      let mediaGeneration = isActive
        ? mediaController.callbackSnapshot.withLock { $0.playbackGeneration }
        : nil
      let acceptedStart = isActive
        ? callbackGenerations.acceptedStart(at: generation)
        : nil
      Task { @MainActor [weak self] in
        guard let self else { return }
        callbackGenerations.performIfCurrent(generation) {
          self.setActiveFromNativeSignal(
            isActive,
            mediaGeneration: mediaGeneration,
            acceptedStart: acceptedStart
          )
        }
      }
    }
  }

  @discardableResult
  private func performWindowControllerAction(_ selector: Selector) -> PiPStartResult {
    // The window controller is created lazily alongside the PiP-ready
    // callback, so "no controller yet" is a real transient state rather than a
    // programming error, and the caller deserves to be told which one it hit.
    guard let windowController, windowController.responds(to: selector) else {
      return .backendUnavailable
    }
    _ = windowController.perform(selector)
    return .accepted
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

  func setActive(
    _ isActive: Bool,
    mediaGeneration: PlaybackGeneration? = nil
  ) {
    setActiveFromNativeSignal(
      isActive,
      mediaGeneration: mediaGeneration,
      acceptedStart: isActive ? callbackGenerations.currentAcceptedStart() : nil
    )
  }

  func setActiveFromNativeSignal(
    _ isActive: Bool,
    mediaGeneration: PlaybackGeneration?,
    acceptedStart: IOSNativePiPCallbackGenerations.AcceptedStart?
  ) {
    guard self.isActive != isActive else { return }
    if isActive {
      let signaledMediaGeneration = mediaGeneration
        ?? owner?.player.generation
        ?? mediaController.player?.generation
      activeMediaGeneration = owner?.attributedNativePiPStartMediaGeneration(
        signaledMediaGeneration: signaledMediaGeneration,
        acceptedRequestMediaGeneration: acceptedStart?.mediaGeneration
      ) ?? acceptedStart?.mediaGeneration ?? signaledMediaGeneration
      callbackGenerations.clearAcceptedStart()
    }
    let lifecycleMediaGeneration = activeMediaGeneration
    self.isActive = isActive
    owner?.handleNativePictureInPictureActiveChanged(
      isActive,
      mediaGeneration: lifecycleMediaGeneration
    )
    if !isActive {
      activeMediaGeneration = nil
    }
  }
}

extension IOSNativePiPMediaController: NativeHandleSnapshotObserver {
  func refreshNativeHandleSnapshot() {
    refreshCallbackSnapshot()
  }

  func invalidateNativeHandleSnapshot() {
    invalidateCallbackSnapshot()
  }
}

final class IOSNativePiPMediaController: NSObject, IOSNativePiPMediaControlling, @unchecked Sendable {
  weak var player: Player? {
    didSet {
      guard oldValue !== player else { return }
      publishCallbackSnapshot(movingRegistrationFrom: oldValue, to: player)
    }
  }

  /// What VLC's native PiP module reads instead of blocking on the main
  /// actor. See ``PiPCallbackSnapshot``.
  let callbackSnapshot = Mutex(PiPCallbackSnapshot())

  /// Publishes without assuming the caller is already on the main actor.
  /// `assumeIsolated` would trap if this nominally nonisolated class is ever
  /// mutated from a background thread — `IOSNativePiPBackend` is `@unchecked
  /// Sendable` and attaches without an isolation guarantee.
  ///
  /// The players are passed rather than re-read on the main actor: on the
  /// asynchronous path the property may already have moved on, and unhooking
  /// the wrong player would leave the outgoing one still refreshing this
  /// snapshot.
  private func publishCallbackSnapshot(
    movingRegistrationFrom outgoing: Player? = nil,
    to incoming: Player? = nil
  ) {
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        moveSnapshotRegistration(from: outgoing, to: incoming)
        refreshCallbackSnapshot()
      }
    } else {
      Task { @MainActor [weak self] in
        self?.moveSnapshotRegistration(from: outgoing, to: incoming)
        self?.refreshCallbackSnapshot()
      }
    }
  }

  /// Follows the attachment: a handle replacement on the newly attached player
  /// has to reach this snapshot, and the player being detached has to stop
  /// refreshing a controller it no longer drives.
  @MainActor
  private func moveSnapshotRegistration(from outgoing: Player?, to incoming: Player?) {
    outgoing?.unregisterNativeHandleSnapshotObserver(self)
    incoming?.registerNativeHandleSnapshotObserver(self)
  }

  /// Republished whenever the attached player changes.
  @MainActor
  func refreshCallbackSnapshot() {
    let pointer = player?.pointer
    let playbackGeneration = player?.generation
    callbackSnapshot.withLock { snapshot in
      if snapshot.playerPointer != pointer {
        snapshot.generation &+= 1
      }
      snapshot.playerPointer = pointer
      snapshot.playbackGeneration = playbackGeneration
    }
  }

  /// Clears the cached handle so in-flight callbacks stop interrogating one
  /// that is being torn down with nothing to replace it.
  @MainActor
  func invalidateCallbackSnapshot() {
    callbackSnapshot.withLock { snapshot in
      if snapshot.playerPointer != nil {
        snapshot.generation &+= 1
      }
      snapshot.playerPointer = nil
      snapshot.playbackGeneration = nil
    }
  }

  weak var owner: PiPController?

  /// The generation the callback snapshot is currently on.
  ///
  /// Every mutating callback below hops to the main actor, and the attached
  /// player can be replaced during that hop. Comparing the generation captured
  /// at entry against the one on arrival is how a command issued for the
  /// previous session is kept from being applied to its successor.
  private var callbackGeneration: UInt64 {
    callbackSnapshot.withLock { $0.generation }
  }

  @objc func play() {
    let issued = callbackGeneration
    Task { @MainActor [weak self] in
      guard let self, callbackGeneration == issued, let player else { return }
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
    let issued = callbackGeneration
    Task { @MainActor [weak self] in
      guard let self, callbackGeneration == issued else { return }
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
    let issued = callbackGeneration
    Task { @MainActor [weak self] in
      // The completion is owed to VLC's PiP module whether or not the seek is
      // applied. Dropping it on a superseded generation would leave the skip
      // it drives unresolved, which is worse than the stale seek being
      // rejected.
      guard let self, callbackGeneration == issued, let player else {
        completion?()
        return
      }

      // One relative-jump path for every PiP backend: see
      // PiPController.performSkip(on:by:). The interval is preserved rather
      // than converted to an absolute target, so live and timeshift DVR
      // windows skip correctly, and completion runs exactly once whether the
      // jump was accepted or refused.
      _ = PiPController.performSkip(
        on: player,
        by: CMTime(value: offset, timescale: 1000)
      )
      completion?()
    }
  }

  // Synchronous queries VLC's native PiP module makes from its own threads.
  // They read the snapshot and then call libVLC after releasing the lock,
  // never blocking on the main actor.

  @objc func mediaLength() -> Int64 {
    guard let pointer = callbackSnapshot.withLock({ $0.playerPointer }) else { return 0 }
    let length = libvlc_media_player_get_length(pointer)
    // VLC's native PiP module checks for VLC_TICK_INVALID (0), not
    // libvlc's public unknown-length sentinel (-1).
    return length > 0 ? length : 0
  }

  @objc func mediaTime() -> Int64 {
    guard let pointer = callbackSnapshot.withLock({ $0.playerPointer }) else { return 0 }
    return max(libvlc_media_player_get_time(pointer), 0)
  }

  @objc func isMediaSeekable() -> Bool {
    guard let pointer = callbackSnapshot.withLock({ $0.playerPointer }) else { return false }
    return libvlc_media_player_is_seekable(pointer)
  }

  @objc func isMediaPlaying() -> Bool {
    // Straight from the player's nonisolated mirror: intent can change on the
    // main actor an instant before the query arrives.
    player?.nonisolatedPlaybackIntent.load(ordering: .acquiring) ?? false
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
