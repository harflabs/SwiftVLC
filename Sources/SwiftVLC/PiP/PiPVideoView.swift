#if os(iOS)
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
  private let startsAutomaticallyFromInline: Bool
  private let managesAudioSession: Bool

  /// Creates a PiP-capable video view.
  ///
  /// Both policy knobs are captured when the underlying view is built
  /// (`makeUIView`); SwiftUI updates that merely re-render this struct
  /// with different knob values do not reconfigure an existing view.
  ///
  /// - Parameters:
  ///   - player: The player whose video output to display.
  ///   - controller: Optional binding to receive the `PiPController` for external control.
  ///   - startsAutomaticallyFromInline: Whether the system may start PiP
  ///     automatically when the app moves to the background while this
  ///     view's video is playing inline. Defaults to `true`. Apps that
  ///     gate playback (parental controls, kiosk lockdowns, watch-time
  ///     policies) should pass `false` so video never escapes to an
  ///     OS-owned window.
  ///   - managesAudioSession: Whether SwiftVLC configures the shared
  ///     `AVAudioSession` (`.playback` category) and activates it on the
  ///     first PiP start or active-playback signal. Defaults to `true`.
  ///     Pass `false` if your app owns its audio-session policy; SwiftVLC
  ///     then never touches the session. Constructing a view for an inactive
  ///     Player does not activate the session. Recreating the native view for
  ///     a Player whose playback intent is already active does activate it so
  ///     automatic PiP cannot outrun the managed audio-session setup.
  public init(
    _ player: Player,
    controller: Binding<PiPController?>? = nil,
    startsAutomaticallyFromInline: Bool = true,
    managesAudioSession: Bool = true
  ) {
    self.player = player
    controllerBinding = controller
    self.startsAutomaticallyFromInline = startsAutomaticallyFromInline
    self.managesAudioSession = managesAudioSession
  }

  public func makeUIView(context: Context) -> UIView {
    let container = IOSNativePiPHostView(
      startsAutomaticallyFromInline: startsAutomaticallyFromInline
    )
    container.attach(to: player)

    let controller = PiPController(
      player: player,
      nativeBackend: container.nativePiPBackend,
      startsAutomaticallyFromInline: startsAutomaticallyFromInline,
      managesAudioSession: managesAudioSession
    )

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
      // `attach(to:)` performs an ownership-checked player handoff. Keeping
      // the transition in one operation is important: a representable
      // dismantle uses `detach()` as a same-player recreation lease when a
      // vout has already opened, while an actual player swap must fully
      // retire the old backend instead.
      container.attach(to: player)

      let controller = PiPController(
        player: player,
        nativeBackend: container.nativePiPBackend,
        startsAutomaticallyFromInline: startsAutomaticallyFromInline,
        managesAudioSession: managesAudioSession
      )

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
    // Clear any external binding so callers who observe it don't retain a
    // stopped controller. The publisher cancels stale make/update work and
    // clears only values this coordinator owns.
    coordinator.clearControllerBinding()
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
    private let bindingPublication = PiPControllerBindingPublication()

    var controllerBinding: Binding<PiPController?>? {
      bindingPublication.currentBinding
    }

    func publishController(
      _ controller: PiPController?,
      to binding: Binding<PiPController?>?
    ) {
      bindingPublication.publish(controller, to: binding)
    }

    func clearControllerBinding() {
      bindingPublication.clear()
    }

    func waitForControllerBindingPublication() async {
      await bindingPublication.waitForPendingPublication()
    }
  }

  @MainActor
  private func pushControllerBinding(_ controller: PiPController?, via coordinator: Coordinator) {
    coordinator.publishController(controller, to: controllerBinding)
  }
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
  private let startsAutomaticallyFromInline: Bool
  private let managesAudioSession: Bool

  /// Creates a PiP-capable video view.
  ///
  /// Both policy knobs exist for API symmetry with the iOS overload and
  /// are **inert on macOS**: auto-PiP-from-inline is an iOS AVKit
  /// concept with no counterpart in the macOS backend, and macOS has no
  /// `AVAudioSession` for SwiftVLC to manage.
  ///
  /// - Parameters:
  ///   - player: The player whose video output to display.
  ///   - controller: Optional binding to receive the `PiPController` for external control.
  ///   - startsAutomaticallyFromInline: Accepted for cross-platform call
  ///     sites; no effect on macOS.
  ///   - managesAudioSession: Accepted for cross-platform call sites; no
  ///     effect on macOS.
  public init(
    _ player: Player,
    controller: Binding<PiPController?>? = nil,
    startsAutomaticallyFromInline: Bool = true,
    managesAudioSession: Bool = true
  ) {
    self.player = player
    controllerBinding = controller
    self.startsAutomaticallyFromInline = startsAutomaticallyFromInline
    self.managesAudioSession = managesAudioSession
  }

  public func makeNSView(context: Context) -> NSView {
    let container = MacNativePiPHostView()
    container.attach(to: player)

    let controller = PiPController(
      player: player,
      nativeBackend: container.nativePiPBackend,
      startsAutomaticallyFromInline: startsAutomaticallyFromInline,
      managesAudioSession: managesAudioSession
    )

    context.coordinator.pipController = controller
    context.coordinator.player = player

    pushControllerBinding(controller, via: context.coordinator)

    return container
  }

  public func updateNSView(_ nsView: NSView, context: Context) {
    guard let container = nsView as? MacNativePiPHostView else { return }
    if context.coordinator.player !== player {
      container.attach(to: player)

      let controller = PiPController(
        player: player,
        nativeBackend: container.nativePiPBackend,
        startsAutomaticallyFromInline: startsAutomaticallyFromInline,
        managesAudioSession: managesAudioSession
      )

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
    coordinator.clearControllerBinding()
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
    private let bindingPublication = PiPControllerBindingPublication()

    var controllerBinding: Binding<PiPController?>? {
      bindingPublication.currentBinding
    }

    func publishController(
      _ controller: PiPController?,
      to binding: Binding<PiPController?>?
    ) {
      bindingPublication.publish(controller, to: binding)
    }

    func clearControllerBinding() {
      bindingPublication.clear()
    }

    func waitForControllerBindingPublication() async {
      await bindingPublication.waitForPendingPublication()
    }
  }

  @MainActor
  private func pushControllerBinding(_ controller: PiPController?, via coordinator: Coordinator) {
    coordinator.publishController(controller, to: controllerBinding)
  }
}

/// SwiftUI owns this root view; VLC mutates the child drawable view.
/// Keeping those responsibilities separate avoids AppKit's unsupported
/// "add PiP internals directly under NSHostingController.view" path.
final class MacNativePiPHostView: NSView {
  private(set) var drawableView: MacNativePiPDrawableView

  var nativePiPBackend: MacNativePiPBackend {
    drawableView.nativePiPBackend
  }

  override init(frame frameRect: NSRect) {
    drawableView = MacNativePiPDrawableView()
    super.init(frame: frameRect)
    wantsLayer = true
    autoresizesSubviews = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.masksToBounds = true

    nativePiPBackend.adopt(hostView: self, drawableView: drawableView)
    drawableView.frame = bounds
    drawableView.autoresizingMask = [.width, .height]
    addSubview(drawableView)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func attach(to player: Player) {
    // A representable can be updated to a different Player in place. Fully
    // retire that Player's attachment while this host still owns the claim;
    // its open vout keeps the exact old drawable alive through Player's
    // native-handle retirement list, while the new Player gets an isolated
    // drawable/backend pair.
    if
      let attachedPlayer = drawableView.attachedPlayer,
      attachedPlayer !== player {
      _ = drawableView.detach(
        owner: self,
        preservingActiveAttachment: false
      )
      install(MacNativePiPDrawableView())
    }

    // Pinned libVLC's macOS vout captures `drawable-nsobject` into the
    // strong `sys->container` exactly once at vout open. A same-Player
    // SwiftUI recreation must therefore adopt and move this exact drawable
    // together with its backend; assigning a new NSView cannot redirect the
    // already-open vout.
    if
      let currentDrawable = player.drawable as? MacNativePiPDrawableView,
      currentDrawable.isAttachment(for: player) {
      install(currentDrawable)
    }

    // `detach()` clears a fully retired backend's weak presentation target.
    // Re-adopting here also makes reuse of the same no-vout host complete.
    install(drawableView)
    if !drawableView.attach(to: player, owner: self) {
      // A stale host can still reference a drawable already claimed by a
      // successor. Never repurpose that shared attachment for another
      // Player; give this host a fresh, isolated surface instead.
      install(MacNativePiPDrawableView())
      _ = drawableView.attach(to: player, owner: self)
    }
  }

  func detach() {
    _ = drawableView.detach(owner: self)
    if drawableView.superview === self {
      drawableView.removeFromSuperview()
    }
  }

  func restoreDrawableView(_ drawableView: MacNativePiPDrawableView) {
    // A closing presenter from a retired Player must not overwrite a host
    // that has since installed a different Player's drawable.
    guard self.drawableView === drawableView else { return }

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

  private func install(_ drawableView: MacNativePiPDrawableView) {
    if self.drawableView !== drawableView {
      self.drawableView.nativePiPBackend.relinquish(
        hostView: self,
        drawableView: self.drawableView
      )
      if self.drawableView.superview === self {
        self.drawableView.removeFromSuperview()
      }
      self.drawableView = drawableView
    }

    let backend = drawableView.nativePiPBackend
    backend.adopt(hostView: self, drawableView: drawableView)
    // During active private PiP the presenter owns the drawable's view
    // hierarchy. Updating its restoration target is enough; pulling the
    // drawable inline here would tear it out of the floating window.
    if !backend.isActive {
      restoreDrawableView(drawableView)
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
  private(set) weak var attachedPlayer: Player?
  private weak var attachmentOwner: AnyObject?
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
    _ = attach(to: player, owner: self)
  }

  func detach() {
    _ = detach(owner: self)
  }

  func isAttachment(for player: Player) -> Bool {
    attachedPlayer === player
      && nativePiPBackend.mediaController.player === player
  }

  @discardableResult
  func attach(to player: Player, owner: AnyObject) -> Bool {
    if
      let attachedPlayer,
      attachedPlayer !== player,
      !detach(owner: owner, preservingActiveAttachment: false) {
      return false
    }

    if attachedPlayer !== player {
      attachedPlayer = player
      nativePiPBackend.attach(to: player)
    }
    nativePiPBackend.drawableView = self
    attachmentOwner = owner
    player.claimDrawableOwnership(owner)
    if !player.isCurrentDrawable(self) {
      player.setDrawable(self, owner: owner)
    }
    return true
  }

  @discardableResult
  func detach(
    owner: AnyObject,
    preservingActiveAttachment: Bool = true
  ) -> Bool {
    guard let player = attachedPlayer else { return true }

    // A successor host can already have adopted this same drawable/backend.
    // Its host claim wins; stale teardown must be a complete no-op.
    guard player.isDrawableOwner(owner) else { return false }

    if preservingActiveAttachment, mustPreserveAttachment(for: player) {
      // Keep `Player.drawable` unchanged as the O(1) handoff lease. The host
      // removes only its own inline parent; an active PiP presenter is left
      // untouched and receives the successor host through backend adoption.
      player.releaseDrawableOwnership(owner)
      attachmentOwner = nil
      return true
    }

    player.releaseDrawableOwnership(owner)
    player.clearDrawable(ifCurrent: self)
    nativePiPBackend.detach()
    attachedPlayer = nil
    attachmentOwner = nil
    lastBounds = .zero
    return true
  }

  private func mustPreserveAttachment(for player: Player) -> Bool {
    if
      player.nativePlayerHasStartedPlayback
      || player.nativePlayerNeedsReplacementBeforePlayback
      || player.attachedMediaListPlayer != nil
      || player.activeVideoOutputs > 0 {
      return true
    }

    switch player.nativePlaybackState {
    case .idle, .stopped, .error:
      return false
    case .opening, .buffering, .playing, .paused, .stopping:
      return true
    }
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
      let attachmentOwner,
      player.isDrawableOwner(attachmentOwner),
      !player.isCurrentDrawable(self),
      lastBounds == .zero,
      bounds.width > 0,
      bounds.height > 0 {
      player.setDrawable(self, owner: attachmentOwner)
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
