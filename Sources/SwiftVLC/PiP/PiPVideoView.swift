#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// A SwiftUI view that renders video via `AVSampleBufferDisplayLayer`,
/// enabling Picture-in-Picture support on iOS.
///
/// Unlike ``VideoView``, which uses `libvlc_media_player_set_nsobject()`,
/// this view uses vmem callbacks for rendering. The two approaches are
/// mutually exclusive; use one or the other for a given player.
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
    let controller = PiPController(player: player)
    let displayLayer = controller.layer

    let container = SampleBufferVideoView(displayLayer: displayLayer)
    container.backgroundColor = .black
    container.clipsToBounds = true

    context.coordinator.pipController = controller
    context.coordinator.displayLayer = displayLayer
    context.coordinator.player = player

    // Defer the binding update. SwiftUI doesn't allow state changes
    // during view construction.
    pushControllerBinding(controller, via: context.coordinator)

    return container
  }

  public func updateUIView(_ uiView: UIView, context: Context) {
    guard let container = uiView as? SampleBufferVideoView else { return }
    if context.coordinator.player !== player {
      context.coordinator.pipController?.stop()

      let controller = PiPController(player: player)
      let displayLayer = controller.layer
      container.setDisplayLayer(displayLayer)

      context.coordinator.player = player
      context.coordinator.pipController = controller
      context.coordinator.displayLayer = displayLayer
    }

    pushControllerBinding(context.coordinator.pipController, via: context.coordinator)
  }

  public static func dismantleUIView(_: UIView, coordinator: Coordinator) {
    coordinator.pipController?.stop()
    coordinator.displayLayer?.removeFromSuperlayer()
    coordinator.pipController = nil
    coordinator.displayLayer = nil
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
  /// Retains the ``PiPController`` and its display layer so they survive
  /// view updates and are cleaned up on dismantle.
  @MainActor
  public final class Coordinator {
    weak var player: Player?
    var pipController: PiPController?
    var displayLayer: AVSampleBufferDisplayLayer?
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

/// UIView subclass that keeps the AVSampleBufferDisplayLayer
/// sized to fill its bounds on every layout pass.
private final class SampleBufferVideoView: UIView {
  private var displayLayer: AVSampleBufferDisplayLayer?

  init(displayLayer: AVSampleBufferDisplayLayer) {
    super.init(frame: .zero)
    setDisplayLayer(displayLayer)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func setDisplayLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
    self.displayLayer?.removeFromSuperlayer()
    self.displayLayer = displayLayer
    layer.addSublayer(displayLayer)
    setNeedsLayout()
    layoutIfNeeded()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Disable implicit animations so the layer doesn't animate to the new size
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer?.frame = bounds
    CATransaction.commit()
  }
}

#elseif os(macOS)
import AppKit
import CLibVLC
import SwiftUI

/// A SwiftUI view that renders video through libVLC's native drawable
/// output and moves that drawable into macOS Picture-in-Picture.
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
      context.coordinator.pipController?.stop()
      container.detach()
      container.attach(to: player)

      let controller = PiPController(player: player, nativeBackend: container.nativePiPBackend)

      context.coordinator.player = player
      context.coordinator.pipController = controller
    }

    pushControllerBinding(context.coordinator.pipController, via: context.coordinator)
  }

  public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.pipController?.stop()
    (nsView as? MacNativePiPHostView)?.detach()
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
    attachedPlayer?.setDrawable(nil)
    attachedPlayer = player
    nativePiPBackend.attach(to: player)
    player.setDrawable(self)
  }

  func detach() {
    guard let player = attachedPlayer else { return }
    nativePiPBackend.stop()
    player.setDrawable(nil)
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

    if let player = attachedPlayer, lastBounds == .zero, bounds.width > 0, bounds.height > 0 {
      player.setDrawable(self)
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

@MainActor
final class MacNativePiPBackend: NSObject, @unchecked Sendable {
  let mediaController = MacNativePiPMediaController()
  weak var owner: PiPController?
  weak var hostView: MacNativePiPHostView?
  weak var drawableView: MacNativePiPDrawableView?

  private let presenter = MacPrivatePiPPresenter()
  private(set) var isPossible = false
  private(set) var isActive = false

  func attach(to player: Player) {
    mediaController.player = player
    refreshPossible()
  }

  func detach() {
    presenter.stop()
    mediaController.player = nil
    setPossible(false)
    setActive(false)
  }

  func start() {
    guard mediaController.player?.currentMedia != nil else {
      return
    }

    refreshPossible()
    guard
      isPossible,
      let hostView,
      let drawableView,
      let player = mediaController.player
    else {
      return
    }

    let didStart = presenter.start(
      player: player,
      hostView: hostView,
      drawableView: drawableView,
      mediaController: mediaController,
      onActiveChanged: { [weak self] isActive in
        self?.setActive(isActive)
      },
      onPlay: { [weak self] in
        self?.handleSetPlaying(true)
      },
      onPause: { [weak self] in
        self?.handleSetPlaying(false)
      }
    )

    if !didStart {
      setPossible(false)
    }
  }

  func stop() {
    presenter.stop()
  }

  func invalidatePlaybackState() {
    presenter.updatePlaybackState(isPlaying: mediaController.isMediaPlaying())
  }

  private func refreshPossible() {
    setPossible(
      mediaController.player?.instance.usesPiPSafeDarwinDisplay == true
        && MacPrivatePiPPresenter.isRuntimeAvailable
    )
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

  private func handleSetPlaying(_ playing: Bool) {
    if let owner {
      owner.handleNativePictureInPictureSetPlaying(playing)
    } else if playing {
      mediaController.play()
    } else {
      mediaController.pause()
    }
  }
}

/// macOS's public sample-buffer PiP path mirrors `AVSampleBufferDisplayLayer`
/// through a `CALayerHost`; on affected macOS releases that mirror renders at
/// 1:1 and crops the video. The private PiP presenter reparents the real VLC
/// drawable instead, which matches the approach used by native macOS players
/// such as IINA. Load it dynamically so unsupported systems simply report PiP
/// unavailable instead of linking a private framework.
@MainActor
private final class MacPrivatePiPPresenter {
  static var isRuntimeAvailable: Bool {
    makePictureInPictureViewController() != nil
  }

  private weak var hostView: MacNativePiPHostView?
  private weak var drawableView: MacNativePiPDrawableView?
  private var pictureInPictureViewController: NSViewController?
  private var contentViewController: NSViewController?
  private var delegate: MacPrivatePiPDelegate?
  private var onActiveChanged: (@MainActor @Sendable (Bool) -> Void)?

  var isActive: Bool {
    pictureInPictureViewController != nil
  }

  func start(
    player: Player,
    hostView: MacNativePiPHostView,
    drawableView: MacNativePiPDrawableView,
    mediaController: MacNativePiPMediaController,
    onActiveChanged: @escaping @MainActor @Sendable (Bool) -> Void,
    onPlay: @escaping @MainActor @Sendable () -> Void,
    onPause: @escaping @MainActor @Sendable () -> Void
  ) -> Bool {
    if isActive {
      updatePlaybackState(isPlaying: mediaController.isMediaPlaying())
      return true
    }

    guard let pictureInPictureViewController = Self.makePictureInPictureViewController() else { return false }

    self.hostView = hostView
    self.drawableView = drawableView
    self.pictureInPictureViewController = pictureInPictureViewController
    self.onActiveChanged = onActiveChanged

    let delegate = MacPrivatePiPDelegate()
    delegate.shouldClose = { [weak self] in
      self?.prepareForClose()
      return true
    }
    delegate.willClose = { [weak self] in
      self?.prepareForClose()
    }
    delegate.didClose = { [weak self] in
      self?.finish()
    }
    delegate.play = onPlay
    delegate.pause = onPause
    delegate.stop = onPause
    self.delegate = delegate

    let contentViewController = NSViewController()
    drawableView.removeFromSuperview()
    drawableView.frame = NSRect(origin: .zero, size: normalizedContentSize(from: hostView.bounds.size))
    drawableView.autoresizingMask = [.width, .height]
    contentViewController.view = drawableView
    self.contentViewController = contentViewController

    guard
      configure(
        pictureInPictureViewController,
        player: player,
        hostView: hostView,
        isPlaying: mediaController.isMediaPlaying()
      ) else {
      finish()
      return false
    }

    _ = pictureInPictureViewController.perform(
      MacPrivatePiPSelector.present,
      with: contentViewController
    )
    onActiveChanged(true)
    return true
  }

  func stop() {
    guard let pictureInPictureViewController else {
      finish()
      return
    }

    prepareForClose()
    if let contentViewController {
      pictureInPictureViewController.dismiss(contentViewController)
    } else {
      finish()
    }
  }

  func updatePlaybackState(isPlaying: Bool) {
    guard let pictureInPictureViewController else { return }
    setPrivateValue(
      isPlaying,
      forKey: "playing",
      requiring: MacPrivatePiPSelector.setPlaying,
      on: pictureInPictureViewController
    )
  }

  @discardableResult
  private func prepareForClose() -> Bool {
    guard let pictureInPictureViewController, let hostView else { return true }
    let replacementRect = hostView.convert(hostView.bounds, to: nil)
    let didSetWindow = setPrivateValue(
      hostView.window,
      forKey: "replacementWindow",
      requiring: MacPrivatePiPSelector.setReplacementWindow,
      on: pictureInPictureViewController
    )
    let didSetRect = setPrivateValue(
      NSValue(rect: replacementRect),
      forKey: "replacementRect",
      requiring: MacPrivatePiPSelector.setReplacementRect,
      on: pictureInPictureViewController
    )
    return didSetWindow && didSetRect
  }

  private func finish() {
    guard pictureInPictureViewController != nil else { return }

    let hostView = hostView
    let drawableView = drawableView

    contentViewController?.view = NSView(frame: .zero)
    if let hostView, let drawableView {
      hostView.restoreDrawableView(drawableView)
    }

    pictureInPictureViewController = nil
    contentViewController = nil
    delegate = nil
    self.hostView = nil
    self.drawableView = nil

    onActiveChanged?(false)
    onActiveChanged = nil
  }

  private func configure(
    _ pictureInPictureViewController: NSViewController,
    player: Player,
    hostView: MacNativePiPHostView,
    isPlaying: Bool
  ) -> Bool {
    pictureInPictureViewController.title = player.currentMedia?.mrl ?? "SwiftVLC"
    let didSetDelegate = setPrivateValue(
      delegate,
      forKey: "delegate",
      requiring: MacPrivatePiPSelector.setDelegate,
      on: pictureInPictureViewController
    )
    let didSetWindow = setPrivateValue(
      hostView.window,
      forKey: "replacementWindow",
      requiring: MacPrivatePiPSelector.setReplacementWindow,
      on: pictureInPictureViewController
    )
    let didSetPlaying = setPrivateValue(
      isPlaying,
      forKey: "playing",
      requiring: MacPrivatePiPSelector.setPlaying,
      on: pictureInPictureViewController
    )
    let didSetRect = setPrivateValue(
      NSValue(rect: hostView.convert(hostView.bounds, to: nil)),
      forKey: "replacementRect",
      requiring: MacPrivatePiPSelector.setReplacementRect,
      on: pictureInPictureViewController
    )
    let didSetAspectRatio = setPrivateValue(
      NSValue(size: normalizedContentSize(from: hostView.bounds.size)),
      forKey: "aspectRatio",
      requiring: MacPrivatePiPSelector.setAspectRatio,
      on: pictureInPictureViewController
    )

    return didSetDelegate
      && didSetWindow
      && didSetPlaying
      && didSetRect
      && didSetAspectRatio
  }

  private func normalizedContentSize(from size: CGSize) -> CGSize {
    guard size.width.isFinite, size.height.isFinite, size.width >= 16, size.height >= 16 else {
      return CGSize(width: 16, height: 9)
    }
    return CGSize(width: ceil(size.width), height: ceil(size.height))
  }

  private static func makePictureInPictureViewController() -> NSViewController? {
    guard let type = loadPictureInPictureViewControllerType() else { return nil }
    let controller = type.init(nibName: nil, bundle: nil)
    guard MacPrivatePiPSelector.required.allSatisfy({ controller.responds(to: $0) }) else {
      return nil
    }
    return controller
  }

  private static func loadPictureInPictureViewControllerType() -> NSViewController.Type? {
    guard
      let bundle = Bundle(path: "/System/Library/PrivateFrameworks/PIP.framework"),
      bundle.isLoaded || bundle.load()
    else {
      return nil
    }
    return NSClassFromString("PIPViewController") as? NSViewController.Type
  }
}

private enum MacPrivatePiPSelector {
  static let present = NSSelectorFromString("presentViewControllerAsPictureInPicture:")
  static let setDelegate = NSSelectorFromString("setDelegate:")
  static let setReplacementWindow = NSSelectorFromString("setReplacementWindow:")
  static let setReplacementRect = NSSelectorFromString("setReplacementRect:")
  static let setPlaying = NSSelectorFromString("setPlaying:")
  static let setAspectRatio = NSSelectorFromString("setAspectRatio:")

  static let required = [
    present,
    setDelegate,
    setReplacementWindow,
    setReplacementRect,
    setPlaying,
    setAspectRatio
  ]
}

@discardableResult
private func setPrivateValue(
  _ value: Any?,
  forKey key: String,
  requiring selector: Selector,
  on object: NSObject
) -> Bool {
  guard object.responds(to: selector) else { return false }
  object.setValue(value, forKey: key)
  return true
}

private final class MacPrivatePiPDelegate: NSObject, @unchecked Sendable {
  var shouldClose: @MainActor @Sendable () -> Bool = { true }
  var willClose: @MainActor @Sendable () -> Void = {}
  var didClose: @MainActor @Sendable () -> Void = {}
  var play: @MainActor @Sendable () -> Void = {}
  var pause: @MainActor @Sendable () -> Void = {}
  var stop: @MainActor @Sendable () -> Void = {}

  @objc(pipShouldClose:)
  func pipShouldClose(_: NSObject) -> Bool {
    pipMainActorSync { [weak self] in
      self?.shouldClose() ?? true
    }
  }

  @objc(pipWillClose:)
  func pipWillClose(_: NSObject) {
    Task { @MainActor [weak self] in
      self?.willClose()
    }
  }

  @objc(pipDidClose:)
  func pipDidClose(_: NSObject) {
    Task { @MainActor [weak self] in
      self?.didClose()
    }
  }

  @objc(pipActionPlay:)
  func pipActionPlay(_: NSObject) {
    Task { @MainActor [weak self] in
      self?.play()
    }
  }

  @objc(pipActionPause:)
  func pipActionPause(_: NSObject) {
    Task { @MainActor [weak self] in
      self?.pause()
    }
  }

  @objc(pipActionStop:)
  func pipActionStop(_: NSObject) {
    Task { @MainActor [weak self] in
      self?.stop()
    }
  }
}

final class MacNativePiPMediaController: NSObject, @unchecked Sendable {
  weak var player: Player?

  @objc func play() {
    Task { @MainActor [weak self] in
      guard let player = self?.player else { return }
      if player.state == .idle || player.state == .stopped {
        try? player.play()
      } else {
        player.resume()
      }
    }
  }

  @objc func pause() {
    Task { @MainActor [weak self] in
      self?.player?.pause()
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
      player.seek(to: .milliseconds(target))
      completion?()
    }
  }

  @objc func mediaLength() -> Int64 {
    pipMainActorSync { [weak self] in
      guard let player = self?.player else { return 0 }
      return max(libvlc_media_player_get_length(player.pointer), 0)
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

#endif
