#if os(iOS)
import AVFoundation
import AVKit
import CLibVLC
import os
import SwiftUI
import UIKit

/// A SwiftUI view that renders video through libVLC's native iOS drawable
/// output and exposes Picture in Picture controls.
///
/// Like ``VideoView``, this view attaches the player with
/// `libvlc_media_player_set_nsobject()`. Its drawable also implements
/// libVLC's Picture in Picture selectors so libVLC can hand SwiftVLC the
/// native PiP window controller when the video output is ready.
///
/// ```swift
/// @State private var pipController: PiPController?
///
/// PiPVideoView(player, controller: $pipController)
///     .onAppear { pipController?.start() }
/// ```
public struct PiPVideoView: UIViewRepresentable {
  private let player: Player
  private let controllerBinding: Binding<PiPController?>?

  /// Creates a PiP-capable video view.
  /// - Parameters:
  ///   - player: The player whose video output to display.
  ///   - controller: Optional binding to receive the `PiPController` for external control.
  public init(_ player: Player, controller: Binding<PiPController?>? = nil) {
    self.player = player
    controllerBinding = controller
  }

  public func makeUIView(context: Context) -> UIView {
    let container = IOSNativePiPHostView()
    container.attach(to: player)

    let controller = PiPController(player: player, nativeBackend: container.nativePiPBackend)

    context.coordinator.pipController = controller
    context.coordinator.player = player

    // Defer the binding update. SwiftUI doesn't allow state changes
    // during view construction.
    pushControllerBinding(controller, via: context.coordinator)

    return container
  }

  public func updateUIView(_ uiView: UIView, context: Context) {
    guard let container = uiView as? IOSNativePiPHostView else { return }
    if context.coordinator.player !== player {
      container.detach()
      container.attach(to: player)

      let controller = PiPController(player: player, nativeBackend: container.nativePiPBackend)

      context.coordinator.player = player
      context.coordinator.pipController = controller
    }

    pushControllerBinding(context.coordinator.pipController, via: context.coordinator)
  }

  public static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
    if let container = uiView as? IOSNativePiPHostView {
      container.detach()
    } else {
      coordinator.pipController?.stop()
    }
    coordinator.pipController = nil
    // Clear any external binding so callers who observe it don't
    // retain a stopped controller.
    if let binding = coordinator.controllerBinding {
      Task { @MainActor in binding.wrappedValue = nil }
      coordinator.controllerBinding = nil
    }
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  /// Internal state for the SwiftUI view's lifecycle.
  ///
  /// Retains the ``PiPController`` so it survives view updates and is
  /// cleaned up on dismantle.
  @MainActor
  public final class Coordinator {
    weak var player: Player?
    var pipController: PiPController?
    var controllerBinding: Binding<PiPController?>?
  }

  @MainActor
  private func pushControllerBinding(_ controller: PiPController?, via coordinator: Coordinator) {
    let binding = controllerBinding
    coordinator.controllerBinding = binding
    Task { @MainActor in
      binding?.wrappedValue = controller
    }
  }
}

final class IOSNativePiPHostView: UIView {
  let drawableView = IOSNativePiPDrawableView()

  var nativePiPBackend: IOSNativePiPBackend {
    drawableView.nativePiPBackend
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
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

@MainActor
final class IOSNativePiPDrawableView: UIView, IOSNativePiPDrawable {
  let nativePiPBackend = IOSNativePiPBackend()
  private weak var attachedPlayer: Player?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    clipsToBounds = true
    nativePiPBackend.drawableView = self
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func attach(to player: Player) {
    if attachedPlayer !== player {
      // Fully tear the backend down before re-attaching: `attach(to:)` only
      // resets the media controller and possible/active flags, so without
      // this the previous player's window-controller wiring (KVO
      // observations + state-change handler) would survive a swap and keep
      // driving PiP state for the wrong player. The production swap path
      // (`updateUIView`) already detaches first; this keeps the method
      // correct for any caller.
      attachedPlayer?.releaseDrawableOwnership(self)
      nativePiPBackend.detach()
      attachedPlayer = player
      nativePiPBackend.attach(to: player)
    }
    player.claimDrawableOwnership(self)
    publishDrawableIfReady()
  }

  func detach() {
    guard let player = attachedPlayer else { return }
    player.releaseDrawableOwnership(self)
    nativePiPBackend.detach()
    attachedPlayer = nil
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

  @objc(mediaController)
  func mediaController() -> AnyObject {
    nativePiPBackend.mediaController
  }

  @objc(pictureInPictureReady)
  func pictureInPictureReady() -> IOSNativePictureInPictureReadyBlock {
    { [weak nativePiPBackend] windowController in
      Task { @MainActor in
        nativePiPBackend?.handlePictureInPictureReady(windowController)
      }
    }
  }

  @objc(canStartPictureInPictureAutomaticallyFromInline)
  func canStartPictureInPictureAutomaticallyFromInline() -> Bool {
    true
  }

  private var hasDrawableBounds: Bool {
    bounds.width > 0 && bounds.height > 0
  }

  private func publishDrawableIfReady() {
    guard let player = attachedPlayer, player.isDrawableOwner(self) else { return }
    if !player.isCurrentDrawable(self) {
      player.setDrawable(self, owner: self)
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
  let mediaController = IOSNativePiPMediaController()
  weak var owner: PiPController? {
    didSet { mediaController.owner = owner }
  }

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
  private var didWarnAboutVideoOutput = false

  private static let logger = Logger(
    subsystem: Signposts.subsystem,
    category: "PictureInPicture"
  )

  func attach(to player: Player) {
    mediaController.player = player
    setPossible(false)
    setActive(false)
  }

  func detach() {
    stop()
    clearWindowController()
    mediaController.player = nil
    setPossible(false)
    setActive(false)
  }

  func handlePictureInPictureReady(_ controller: AnyObject) {
    guard let controller = controller as? NSObject else { return }

    clearWindowController()
    guard Self.supportsNativePictureInPictureRendering else {
      setPossible(false)
      setActive(false)
      return
    }

    windowController = controller
    installStateChangeHandler(on: controller)
    observeAVPictureInPictureController(on: controller)

    if avPictureInPictureController == nil {
      setPossible(true)
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
    performWindowControllerAction(IOSNativePiPSelector.invalidatePlaybackState)
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

  private func installStateChangeHandler(on controller: NSObject) {
    guard controller.responds(to: IOSNativePiPSelector.setStateChangeEventHandler) else { return }

    let handler: IOSNativePiPStateChangeEventHandler = { [weak self] isStarted in
      Task { @MainActor in
        self?.setActive(isStarted)
      }
    }
    stateChangeEventHandler = handler
    controller.setValue(handler, forKey: "stateChangeEventHandler")
  }

  private func observeAVPictureInPictureController(on controller: NSObject) {
    guard controller.responds(to: IOSNativePiPSelector.avPictureInPictureController) else { return }
    guard let avController = controller.value(forKey: "avPipController") as? AVPictureInPictureController else { return }

    avPictureInPictureController = avController
    setPossible(avController.isPictureInPicturePossible)
    setActive(avController.isPictureInPictureActive)

    possibleObservation = avController.observe(
      \.isPictureInPicturePossible,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
      let isPossible = controller.isPictureInPicturePossible
      Task { @MainActor [weak self] in
        self?.setPossible(isPossible)
      }
    }

    activeObservation = avController.observe(
      \.isPictureInPictureActive,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
      let isActive = controller.isPictureInPictureActive
      Task { @MainActor [weak self] in
        self?.setActive(isActive)
      }
    }
  }

  private func performWindowControllerAction(_ selector: Selector) {
    guard let windowController, windowController.responds(to: selector) else { return }
    _ = windowController.perform(selector)
  }

  private func setPossible(_ isPossible: Bool) {
    guard self.isPossible != isPossible else { return }
    self.isPossible = isPossible
    Task { @MainActor [weak owner] in
      owner?.handleNativePictureInPictureReady()
    }
  }

  private func setActive(_ isActive: Bool) {
    guard self.isActive != isActive else { return }
    self.isActive = isActive
    Task { @MainActor [weak owner] in
      owner?.handleNativePictureInPictureActiveChanged(isActive)
    }
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

      let duration = player.duration?.milliseconds ?? Int64.max
      let target = max(0, min(player.currentTime.milliseconds + offset, duration))
      try? player.seek(to: .milliseconds(target))
      completion?()
    }
  }

  @objc func mediaLength() -> Int64 {
    pipMainActorSync { [weak self] in
      guard let player = self?.player else { return -1 }
      let length = libvlc_media_player_get_length(player.pointer)
      return length > 0 ? length : -1
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

#elseif os(macOS)
import AppKit
import CLibVLC
import SwiftUI

/// A SwiftUI view that renders video through libVLC's native drawable
/// output on macOS.
///
/// The native Picture-in-Picture start path is unavailable by default.
/// Non-App-Store builds can opt into it through SwiftVLC's
/// `PrivateMacOSPiP` SPI, which uses private Apple framework symbols and
/// is outside the public compatibility contract.
public struct PiPVideoView: NSViewRepresentable {
  private let player: Player
  private let controllerBinding: Binding<PiPController?>?

  /// Creates a PiP-capable video view.
  /// - Parameters:
  ///   - player: The player whose video output to display.
  ///   - controller: Optional binding to receive the `PiPController` for external control.
  public init(_ player: Player, controller: Binding<PiPController?>? = nil) {
    self.player = player
    controllerBinding = controller
  }

  public func makeNSView(context: Context) -> NSView {
    let container = MacNativePiPHostView()
    container.attach(to: player)

    let controller = PiPController(player: player, nativeBackend: container.nativePiPBackend)

    context.coordinator.pipController = controller
    context.coordinator.player = player

    pushControllerBinding(controller, via: context.coordinator)

    return container
  }

  public func updateNSView(_ nsView: NSView, context: Context) {
    guard let container = nsView as? MacNativePiPHostView else { return }
    if context.coordinator.player !== player {
      container.detach()
      container.attach(to: player)

      let controller = PiPController(player: player, nativeBackend: container.nativePiPBackend)

      context.coordinator.player = player
      context.coordinator.pipController = controller
    }

    pushControllerBinding(context.coordinator.pipController, via: context.coordinator)
  }

  public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    if let container = nsView as? MacNativePiPHostView {
      container.detach()
    } else {
      coordinator.pipController?.stop()
    }
    coordinator.pipController = nil
    if let binding = coordinator.controllerBinding {
      Task { @MainActor in binding.wrappedValue = nil }
      coordinator.controllerBinding = nil
    }
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  /// Internal state for the SwiftUI view's lifecycle.
  ///
  /// Retains the ``PiPController`` so it survives view updates and is
  /// cleaned up on dismantle.
  @MainActor
  public final class Coordinator {
    weak var player: Player?
    var pipController: PiPController?
    var controllerBinding: Binding<PiPController?>?
  }

  @MainActor
  private func pushControllerBinding(_ controller: PiPController?, via coordinator: Coordinator) {
    let binding = controllerBinding
    coordinator.controllerBinding = binding
    Task { @MainActor in
      binding?.wrappedValue = controller
    }
  }
}

/// SwiftUI owns this root view; VLC mutates the child drawable view.
/// Keeping those responsibilities separate avoids AppKit's unsupported
/// "add PiP internals directly under NSHostingController.view" path.
final class MacNativePiPHostView: NSView {
  let drawableView = MacNativePiPDrawableView()

  var nativePiPBackend: MacNativePiPBackend {
    drawableView.nativePiPBackend
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    autoresizesSubviews = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.masksToBounds = true

    nativePiPBackend.hostView = self
    drawableView.frame = bounds
    drawableView.autoresizingMask = [.width, .height]
    addSubview(drawableView)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func attach(to player: Player) {
    drawableView.attach(to: player)
  }

  func detach() {
    drawableView.detach()
  }

  func restoreDrawableView(_ drawableView: MacNativePiPDrawableView) {
    if drawableView.superview !== self {
      drawableView.removeFromSuperview()
      addSubview(drawableView)
    }

    drawableView.autoresizingMask = [.width, .height]
    drawableView.frame = bounds
    drawableView.restoreVLCContentLayout()
    needsLayout = true
    layoutSubtreeIfNeeded()
    drawableView.restoreVLCContentLayout()

    DispatchQueue.main.async { [weak self, weak drawableView] in
      guard let self, let drawableView, drawableView.superview === self else { return }
      drawableView.frame = bounds
      drawableView.restoreVLCContentLayout()
    }
  }

  override func layout() {
    super.layout()
    guard drawableView.superview === self else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    drawableView.frame = bounds
    CATransaction.commit()
  }
}

final class MacNativePiPDrawableView: NSView {
  let nativePiPBackend = MacNativePiPBackend()
  private weak var attachedPlayer: Player?
  private var lastBounds: CGRect = .zero

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    autoresizesSubviews = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.masksToBounds = true
    nativePiPBackend.drawableView = self
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func attach(to player: Player) {
    guard attachedPlayer !== player else { return }
    attachedPlayer?.releaseDrawableOwnership(self)
    attachedPlayer = player
    nativePiPBackend.attach(to: player)
    player.claimDrawableOwnership(self)
    player.setDrawable(self, owner: self)
  }

  func detach() {
    guard let player = attachedPlayer else { return }
    player.releaseDrawableOwnership(self)
    nativePiPBackend.detach()
    attachedPlayer = nil
    lastBounds = .zero
  }

  @objc(addVoutSubview:)
  func addVoutSubview(_ subview: NSView) {
    if subview.superview !== self {
      subview.removeFromSuperview()
      addSubview(subview)
    }
    configureVLCSubview(subview)
    restoreVLCContentLayout()
  }

  @objc(removeVoutSubview:)
  func removeVoutSubview(_ subview: NSView) {
    guard subview.superview === self else { return }
    subview.removeFromSuperview()
  }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    configureVLCSubview(subview)
    layoutVLCContent()
  }

  override func layout() {
    super.layout()

    if
      let player = attachedPlayer,
      player.isDrawableOwner(self),
      !player.isCurrentDrawable(self),
      lastBounds == .zero,
      bounds.width > 0,
      bounds.height > 0 {
      player.setDrawable(self, owner: self)
    }
    if bounds.width > 0, bounds.height > 0 {
      lastBounds = bounds
    }

    layoutVLCContent()
  }

  private func configureVLCSubview(_ subview: NSView) {
    subview.autoresizingMask = [.width, .height]
  }

  func restoreVLCContentLayout() {
    needsLayout = true
    layoutSubtreeIfNeeded()
    layoutVLCContent()
  }

  private func layoutVLCContent() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for subview in subviews {
      configureVLCSubview(subview)
      subview.frame = bounds
      subview.needsLayout = true
      subview.layoutSubtreeIfNeeded()
      reshapeVLCSubviewIfNeeded(subview)
      subview.layer?.frame = subview.bounds
      subview.layer?.setNeedsDisplay()
    }
    layer?.sublayers?.forEach {
      $0.frame = bounds
      $0.setNeedsDisplay()
    }
    CATransaction.commit()
  }
}

private let macNativePiPOpenGLReshapeSelector = NSSelectorFromString("reshape")

@MainActor
private func reshapeVLCSubviewIfNeeded(_ subview: NSView) {
  guard
    subview.responds(to: macNativePiPOpenGLReshapeSelector),
    subview.bounds.width > 0,
    subview.bounds.height > 0
  else { return }
  _ = subview.perform(macNativePiPOpenGLReshapeSelector)
}

#endif
