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
import AVFoundation
import SwiftUI

/// A SwiftUI view that renders video via `AVSampleBufferDisplayLayer`,
/// enabling Picture-in-Picture support on macOS.
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
    let controller = PiPController(player: player)
    let displayLayer = controller.layer

    let container = SampleBufferVideoView(displayLayer: displayLayer)

    context.coordinator.pipController = controller
    context.coordinator.displayLayer = displayLayer
    context.coordinator.player = player

    pushControllerBinding(controller, via: context.coordinator)

    return container
  }

  public func updateNSView(_ nsView: NSView, context: Context) {
    guard let container = nsView as? SampleBufferVideoView else { return }
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

  public static func dismantleNSView(_: NSView, coordinator: Coordinator) {
    coordinator.pipController?.stop()
    coordinator.displayLayer?.removeFromSuperlayer()
    coordinator.pipController = nil
    coordinator.displayLayer = nil
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

private final class SampleBufferVideoView: NSView {
  private var displayLayer: AVSampleBufferDisplayLayer?

  init(displayLayer: AVSampleBufferDisplayLayer) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    setDisplayLayer(displayLayer)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func setDisplayLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
    self.displayLayer?.removeFromSuperlayer()
    self.displayLayer = displayLayer
    layer?.addSublayer(displayLayer)
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer?.frame = bounds
    CATransaction.commit()
  }
}

#endif
