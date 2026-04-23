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
/// Drawable ownership lives on ``Player`` via ``Player/setDrawable(_:)``;
/// this surface only reports to the player when it is attached or
/// detached. Routing the libVLC call through the player guarantees the
/// view is strongly retained for the lifetime of the attachment, which
/// keeps libVLC's asynchronous decode-thread reads of the drawable
/// pointer safe even if UIKit releases the view before `dismantleUIView`
/// runs.
@MainActor
final class VideoSurface: UIView {
  private weak var attachedPlayer: Player?
  private var lastBounds: CGRect = .zero

  func attach(to player: Player) {
    guard attachedPlayer !== player else { return }
    attachedPlayer?.setDrawable(nil)
    attachedPlayer = player
    player.setDrawable(self)
  }

  func detach() {
    guard let player = attachedPlayer else { return }
    player.setDrawable(nil)
    attachedPlayer = nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    // First valid layout: re-assert the drawable so libVLC can attach
    // its rendering subview once we have non-zero bounds. Both width
    // and height must be non-zero; attaching at `(>0, 0)` creates the
    // rendering subview at zero height and a later resize doesn't
    // retroactively fix the initial parenting.
    if let player = attachedPlayer, lastBounds == .zero, bounds.width > 0, bounds.height > 0 {
      player.setDrawable(self)
    }

    // Keep VLC's rendering sublayer sized to our bounds
    if bounds != lastBounds, bounds.width > 0, bounds.height > 0 {
      lastBounds = bounds
      layer.sublayers?.forEach { sublayer in
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sublayer.frame = bounds
        CATransaction.commit()
      }
    }
  }
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
/// ``Player/setDrawable(_:)``, which retains the view for the duration
/// of the attachment so libVLC's decode-thread reads never outlive it.
@MainActor
final class VideoSurface: NSView {
  private weak var attachedPlayer: Player?
  private var lastBounds: CGRect = .zero

  func attach(to player: Player) {
    guard attachedPlayer !== player else { return }
    attachedPlayer?.setDrawable(nil)
    attachedPlayer = player
    player.setDrawable(self)
  }

  func detach() {
    guard let player = attachedPlayer else { return }
    player.setDrawable(nil)
    attachedPlayer = nil
  }

  override func layout() {
    super.layout()

    if bounds != lastBounds, bounds.width > 0, bounds.height > 0 {
      lastBounds = bounds
      layer?.sublayers?.forEach { sublayer in
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sublayer.frame = bounds
        CATransaction.commit()
      }
    }
  }
}

#endif
