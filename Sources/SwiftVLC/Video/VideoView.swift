import CLibVLC
import SwiftUI

#if canImport(UIKit)
import UIKit

/// A SwiftUI view that renders video from a ``Player``.
///
/// The entire public API for video rendering is one line:
/// ```swift
/// VideoView(player)
///     .frame(maxWidth: .infinity)
/// ```
///
/// No `UIViewRepresentable` coordinator, no delegate proxy, no
/// lifecycle wiring.
public struct VideoView: UIViewRepresentable {
  private let player: Player

  /// Creates a video view attached to a player.
  /// - Parameter player: The player whose video output to display.
  public init(_ player: Player) {
    self.player = player
  }

  public func makeUIView(context _: Context) -> UIView {
    let surface = VideoSurface()
    surface.backgroundColor = .black
    surface.clipsToBounds = true
    surface.isUserInteractionEnabled = false
    return surface
  }

  public func updateUIView(_ uiView: UIView, context _: Context) {
    (uiView as? VideoSurface)?.attach(to: player)
  }

  public static func dismantleUIView(_ uiView: UIView, coordinator _: ()) {
    (uiView as? VideoSurface)?.detach()
  }
}

/// Internal UIView that serves as the video drawable surface.
///
/// libVLC's `set_nsobject` creates its own rendering subview and adds it
/// to the drawable view. We handle sublayer frame updates automatically.
///
/// Drawable ownership lives on ``Player`` via `Player.setDrawable(_:)`;
/// this surface only reports to the player when it is attached or
/// detached. Routing the libVLC call through the player guarantees the
/// view is strongly retained for the lifetime of the attachment, which
/// keeps libVLC's asynchronous decode-thread reads of the drawable
/// pointer safe even if UIKit releases the view before `dismantleUIView`
/// runs.
@MainActor
final class VideoSurface: UIView {
  private weak var attachedPlayer: Player?

  func attach(to player: Player) {
    if attachedPlayer !== player {
      attachedPlayer?.releaseDrawableOwnership(self)
      attachedPlayer = player
    }
    player.claimDrawableOwnership(self)
    publishDrawableIfReady()
  }

  func detach() {
    guard let player = attachedPlayer else { return }
    player.releaseDrawableOwnership(self)
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
    #if os(visionOS)
    let scale = layer.contentsScale
    #else
    let scale = window?.screen.scale
      ?? subview.window?.screen.scale
      ?? UIScreen.main.scale
    #endif
    subview.contentScaleFactor = scale
    subview.layer.contentsScale = scale
  }
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

#elseif canImport(AppKit)
import AppKit

/// A SwiftUI view that renders video from a ``Player``.
///
/// ```swift
/// VideoView(player)
///     .frame(maxWidth: .infinity)
/// ```
public struct VideoView: NSViewRepresentable {
  private let player: Player

  /// Creates a video view attached to a player.
  /// - Parameter player: The player whose video output to display.
  public init(_ player: Player) {
    self.player = player
  }

  public func makeNSView(context _: Context) -> NSView {
    let surface = VideoSurface()
    surface.wantsLayer = true
    surface.layer?.backgroundColor = NSColor.black.cgColor
    surface.layer?.masksToBounds = true
    surface.autoresizesSubviews = true
    return surface
  }

  public func updateNSView(_ nsView: NSView, context _: Context) {
    (nsView as? VideoSurface)?.attach(to: player)
  }

  public static func dismantleNSView(_ nsView: NSView, coordinator _: ()) {
    (nsView as? VideoSurface)?.detach()
  }
}

/// AppKit counterpart to the UIKit `VideoSurface`. Same ownership
/// model: the surface delegates drawable attachment to
/// `Player.setDrawable(_:)`, which retains the view for the duration
/// of the attachment so libVLC's decode-thread reads never outlive it.
@MainActor
final class VideoSurface: NSView {
  private weak var attachedPlayer: Player?

  override var wantsDefaultClipping: Bool {
    true
  }

  func attach(to player: Player) {
    if attachedPlayer !== player {
      attachedPlayer?.releaseDrawableOwnership(self)
      attachedPlayer = player
    }
    player.claimDrawableOwnership(self)
    publishDrawableIfReady()
  }

  func detach() {
    guard let player = attachedPlayer else { return }
    player.releaseDrawableOwnership(self)
    attachedPlayer = nil
  }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    subview.frame = bounds
    subview.autoresizingMask = [.width, .height]
    reshapeVLCSubviewIfNeeded(subview)
  }

  override func layout() {
    super.layout()

    guard hasDrawableBounds else { return }

    publishDrawableIfReady()
    resizeRenderingChildren()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      publishDrawableIfReady()
      needsLayout = true
      layer?.setNeedsLayout()
    }
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
    for subview in subviews {
      resizeRenderingSubview(subview)
    }
    layer?.sublayers?.forEach { sublayer in
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      sublayer.frame = bounds
      CATransaction.commit()
    }
  }

  private func resizeRenderingSubview(_ subview: NSView) {
    guard hasDrawableBounds else { return }
    subview.frame = bounds
    reshapeVLCSubviewIfNeeded(subview)
  }
}

private let vlcOpenGLReshapeSelector = NSSelectorFromString("reshape")

@MainActor
private func reshapeVLCSubviewIfNeeded(_ subview: NSView) {
  guard
    subview.responds(to: vlcOpenGLReshapeSelector),
    subview.bounds.width > 0,
    subview.bounds.height > 0
  else { return }
  _ = subview.perform(vlcOpenGLReshapeSelector)
}

#endif
