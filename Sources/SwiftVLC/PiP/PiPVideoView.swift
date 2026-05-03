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
