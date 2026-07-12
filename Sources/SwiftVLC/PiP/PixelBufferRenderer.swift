#if os(iOS) || os(macOS)
import AVFoundation
import CLibVLC
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os
import Synchronization

/// Core Image objects shared by every scaled frame produced by one renderer.
/// Kept in a reference type so tests can verify identity reuse and `State`
/// copies never duplicate resource ownership.
final class PixelBufferScalingResources: @unchecked Sendable {
  let context = CIContext(options: [.cacheIntermediates: false])
  let colorSpace = CGColorSpaceCreateDeviceRGB()
}

/// Renders libVLC video frames into `CVPixelBuffer`s via vmem callbacks,
/// then enqueues them as `CMSampleBuffer`s onto an `AVSampleBufferDisplayLayer`.
///
/// Thread safety: all vmem callbacks run on libVLC's decode thread.
/// `Mutex<State>` protects shared state accessed from both the decode thread and main thread.
final class PixelBufferRenderer: Sendable {
  /// @unchecked because CF types (CVPixelBufferPool, CMTimebase) lack
  /// Sendable conformance. Thread safety is guaranteed by the enclosing
  /// Mutex.
  struct State: @unchecked Sendable {
    struct CachedFormatDescription: @unchecked Sendable {
      let generation: UInt64
      let description: CMVideoFormatDescription
    }

    var pool: CVPixelBufferPool?
    var width: Int = 0
    var height: Int = 0
    var renderSize: CMVideoDimensions?
    var renderPool: CVPixelBufferPool?
    var renderPoolWidth: Int = 0
    var renderPoolHeight: Int = 0
    var renderGeneration: UInt64 = 0
    var cachedFormatDescription: CachedFormatDescription?
    var formatDescriptionCreationCount: UInt64 = 0
    var scalingResources: PixelBufferScalingResources?
    /// The display layer is held inside a class box rather than as a
    /// direct `weak var` on the struct. `Mutex` stores `State` in raw
    /// managed memory and any `withLock { $0 }` read produces a struct
    /// copy; bit-copying a `__weak` slot side-steps the ObjC runtime's
    /// weak-reference table and surfaces as "unregister unknown __weak
    /// variable" warnings at teardown. The box gives the weak a single
    /// stable home the runtime can track across struct copies.
    let displayLayer: DisplayLayerBox
    var timebase: CMTimebase?

    init(displayLayer: AVSampleBufferDisplayLayer?) {
      self.displayLayer = DisplayLayerBox(displayLayer)
    }

    mutating func advanceRenderGeneration() {
      renderGeneration &+= 1
      cachedFormatDescription = nil
    }
  }

  let state: Mutex<State>
  let enqueueQueue: DispatchQueue
  let enqueueState = Mutex(PixelBufferEnqueueState())
  let displayLayerAPI: PixelBufferDisplayLayerAPI

  init(
    displayLayer: AVSampleBufferDisplayLayer? = nil,
    enqueueQueue: DispatchQueue? = nil,
    displayLayerAPI: PixelBufferDisplayLayerAPI = .live
  ) {
    state = Mutex(State(displayLayer: displayLayer))
    self.enqueueQueue = enqueueQueue ?? DispatchQueue(
      label: "org.swiftvlc.pixel-buffer-renderer.enqueue"
    )
    self.displayLayerAPI = displayLayerAPI
  }

  func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer?) {
    state.withLock { $0.displayLayer.layer = layer }
  }

  func setTimebase(_ tb: CMTimebase?) {
    state.withLock { $0.timebase = tb }
  }

  func setRenderSize(_ size: CMVideoDimensions?) {
    state.withLock {
      guard $0.renderSize?.width != size?.width || $0.renderSize?.height != size?.height else {
        return
      }
      $0.renderSize = size
      $0.renderPool = nil
      $0.renderPoolWidth = 0
      $0.renderPoolHeight = 0
      $0.advanceRenderGeneration()
    }
  }

  func flushDisplayLayer() {
    let layer = state.withLock { $0.displayLayer.layer }
    DispatchQueue.main.async { [layer] in
      layer?.sampleBufferRenderer.flush()
    }
  }

  func outputPixelBuffer(from source: CVPixelBuffer) -> (buffer: CVPixelBuffer, generation: UInt64)? {
    let interval = Signposts.signposter.beginInterval("PixelBufferRenderer.outputPixelBuffer")
    defer { Signposts.signposter.endInterval("PixelBufferRenderer.outputPixelBuffer", interval) }
    let (target, generation) = state.withLock { ($0.renderSize, $0.renderGeneration) }
    guard
      let target,
      target.width > 0,
      target.height > 0
    else {
      return (source, generation)
    }

    let width = Int(target.width)
    let height = Int(target.height)
    if CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height {
      return (source, generation)
    }

    guard let output = makeRenderPixelBuffer(width: width, height: height) else {
      return nil
    }

    let sourceWidth = CGFloat(CVPixelBufferGetWidth(source))
    let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
    let targetWidth = CGFloat(width)
    let targetHeight = CGFloat(height)
    guard sourceWidth > 0, sourceHeight > 0 else { return (source, generation) }

    let scale = min(targetWidth / sourceWidth, targetHeight / sourceHeight)
    let fittedWidth = sourceWidth * scale
    let fittedHeight = sourceHeight * scale
    let offsetX = (targetWidth - fittedWidth) / 2
    let offsetY = (targetHeight - fittedHeight) / 2

    let transform = CGAffineTransform(
      a: scale,
      b: 0,
      c: 0,
      d: scale,
      tx: offsetX,
      ty: offsetY
    )
    let frame = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
    let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
      .cropped(to: frame)
    let image = CIImage(cvPixelBuffer: source)
      .transformed(by: transform)
      .composited(over: background)

    let resources = scalingResourcesForResize()
    resources.context.render(
      image,
      to: output,
      bounds: frame,
      colorSpace: resources.colorSpace
    )
    return (output, generation)
  }

  private func scalingResourcesForResize() -> PixelBufferScalingResources {
    state.withLock { state in
      if let resources = state.scalingResources {
        return resources
      }
      let resources = PixelBufferScalingResources()
      state.scalingResources = resources
      return resources
    }
  }

  private func makeRenderPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    let pool = state.withLock { state -> CVPixelBufferPool? in
      if state.renderPoolWidth == width, state.renderPoolHeight == height, let pool = state.renderPool {
        return pool
      }

      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
      ]
      let poolAttrs: [String: Any] = [
        kCVPixelBufferPoolMinimumBufferCountKey as String:
          pixelBufferRendererPoolMinimumBufferCount(width: width, height: height)
      ]

      var newPool: CVPixelBufferPool?
      let status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        poolAttrs as CFDictionary,
        attrs as CFDictionary,
        &newPool
      )
      guard status == kCVReturnSuccess, let newPool else { return nil }

      state.renderPool = newPool
      state.renderPoolWidth = width
      state.renderPoolHeight = height
      return newPool
    }

    guard let pool else { return nil }
    let allocation = pixelBufferRendererAllocatePixelBuffer(
      from: pool,
      width: width,
      height: height
    )
    guard allocation.status == kCVReturnSuccess else { return nil }
    return allocation.buffer
  }
}

/// Injectable native registration operations. Production uses libVLC; tests
/// record the exact handle each install/clear targets without requiring a
/// timing-sensitive video output.
struct DirectPiPVideoCallbackAPI {
  let install: @MainActor (OpaquePointer, UnsafeMutableRawPointer) -> Void
  let clear: @MainActor (OpaquePointer) -> Void

  static var live: Self {
    Self(
      install: { player, opaque in
        libvlc_video_set_callbacks(
          player,
          pixelBufferLockCallback,
          pixelBufferUnlockCallback,
          pixelBufferDisplayCallback,
          opaque
        )
        let installedExtended = swiftvlc_video_set_format_callbacks_ex_if_available(
          player,
          pixelBufferFormatCallbackEx,
          pixelBufferCleanupCallback
        )
        if !installedExtended {
          // A libVLC binary without the extended `_ex` format callbacks cannot
          // supply atomic vmem geometry. Fall back to the legacy callback,
          // which cannot prove crop/PAR.
          libvlc_video_set_format_callbacks(
            player,
            pixelBufferFormatCallback,
            pixelBufferCleanupCallback
          )
        }
      },
      clear: { player in
        libvlc_video_set_callbacks(player, nil, nil, nil, nil)
        if !swiftvlc_video_set_format_callbacks_ex_if_available(player, nil, nil) {
          libvlc_video_set_format_callbacks(player, nil, nil)
        }
      }
    )
  }
}

/// The stable callback slot for one exact native-player handle.
///
/// libVLC copies `vmem` callbacks and their opaque value when a video output
/// opens. Replacing the media-player variables does not update that copy, so
/// every controller using the same native handle must share this slot. The
/// copied handle opaque routes display to the current controller; setup then
/// replaces each vout's copy with a retained per-vout opaque and decode pool.
/// A replacement native handle receives a new slot and handle opaque.
@MainActor
final class DirectPiPVideoCallbackSlot {
  let lifetime: NativePlayerHandleLifetime
  let context: PixelBufferRendererCallbackContext
  let opaque: UnsafeMutableRawPointer
  private let api: DirectPiPVideoCallbackAPI
  private var callbacksInstalled = false
  private(set) var isRetired = false

  init(
    lifetime: NativePlayerHandleLifetime,
    decodeRenderer: PixelBufferRenderer,
    api: DirectPiPVideoCallbackAPI
  ) {
    precondition(!lifetime.isReleased)
    self.lifetime = lifetime
    self.api = api
    let context = PixelBufferRendererCallbackContext(renderer: decodeRenderer)
    self.context = context
    let retained = Unmanaged.passRetained(context)
    let opaque = retained.toOpaque()
    self.opaque = opaque
    nonisolated(unsafe) let callbackOpaque = opaque
    let accepted = lifetime.whenReleased { [context] in
      context.nativePlayerHandleDidRelease(opaque: callbackOpaque)
    }
    precondition(accepted, "Cannot create callbacks for a released native player handle")
  }

  /// Makes `renderer` the destination for this handle's frames and restores
  /// the same handle opaque into the media-player variables for future vouts.
  /// An already-open vout owns a child opaque that resolves through this same
  /// handle context and observes the handoff on its next display callback.
  func activate(renderer: PixelBufferRenderer) {
    precondition(!isRetired && !lifetime.isReleased)
    precondition(context.setDisplayRenderer(renderer))
    if !callbacksInstalled {
      api.install(lifetime.pointer, opaque)
      callbacksInstalled = true
    }
  }

  /// Removes the controller target while preserving the per-handle slot.
  /// A later controller can reactivate this same opaque, including when an
  /// already-open vout still holds it. The media-player variables are cleared
  /// while the slot is dormant and reinstalled with this same opaque on the
  /// next activation.
  func deactivate() {
    guard !isRetired else { return }
    _ = context.setDisplayRenderer(nil)
    clearCallbacksIfInstalled()
  }

  /// Permanently retires the slot because its exact handle is being replaced
  /// or released. The opaque remains retained by `lifetime` until native
  /// teardown has joined that handle's vout.
  func retire() {
    guard !isRetired else { return }
    isRetired = true
    context.requestRetirement()
    clearCallbacksIfInstalled()
  }

  private func clearCallbacksIfInstalled() {
    guard callbacksInstalled else { return }
    callbacksInstalled = false
    api.clear(lifetime.pointer)
  }
}

/// One logical direct-PiP controller claim. The Player binds it to the stable
/// slot for the current native handle and uses the generation to reject stale
/// teardown from a superseded controller.
@MainActor
final class DirectPiPVideoCallbackRegistration {
  private struct Binding {
    let slot: DirectPiPVideoCallbackSlot
    let generation: UInt64
  }

  private let renderer: PixelBufferRenderer
  private let api: DirectPiPVideoCallbackAPI
  private var current: Binding?

  init(
    renderer: PixelBufferRenderer,
    api: DirectPiPVideoCallbackAPI = .live
  ) {
    self.renderer = renderer
    self.api = api
  }

  func makeSlot(on lifetime: NativePlayerHandleLifetime) -> DirectPiPVideoCallbackSlot {
    DirectPiPVideoCallbackSlot(
      lifetime: lifetime,
      decodeRenderer: renderer,
      api: api
    )
  }

  func bind(to slot: DirectPiPVideoCallbackSlot, generation: UInt64) {
    slot.activate(renderer: renderer)
    current = Binding(slot: slot, generation: generation)
  }

  func unbind(generation: UInt64) {
    guard current?.generation == generation else { return }
    current = nil
  }

  var currentGeneration: UInt64? {
    current?.generation
  }

  var currentLifetime: NativePlayerHandleLifetime? {
    current?.slot.lifetime
  }

  var currentSlot: DirectPiPVideoCallbackSlot? {
    current?.slot
  }

  var currentContextForTesting: PixelBufferRendererCallbackContext? {
    current?.slot.context
  }

  var currentOpaqueForTesting: UnsafeMutableRawPointer? {
    current?.slot.opaque
  }
}

/// Stable object passed to libVLC's vmem callbacks.
///
/// libVLC copies the callback function pointers and `opaque` value into a
/// video output while it opens. Clearing or replacing the media-player
/// variables cannot prove that no future callback will use that copy. The
/// opaque retain is therefore released only when its exact
/// ``NativePlayerHandleLifetime`` ends, never from a timeout or a transient
/// `voutOpen == false` observation.
final class PixelBufferRendererCallbackContext: Sendable {
  private struct CallbackEntry {
    let displayRenderer: PixelBufferRenderer?
  }

  private struct State: @unchecked Sendable {
    var displayRenderer: PixelBufferRenderer?
    var activeCallbacks = 0
    var openVoutCount = 0
    var retirementRequested = false
    var nativePlayerHandleReleased = false
    var opaqueRetainReleased = false
  }

  private let state: Mutex<State>

  init(renderer: PixelBufferRenderer) {
    state = Mutex(State(displayRenderer: renderer))
  }

  var hasOpenVoutForTesting: Bool {
    state.withLock { $0.openVoutCount > 0 }
  }

  var retirementRequestedForTesting: Bool {
    state.withLock { $0.retirementRequested }
  }

  var nativePlayerHandleReleasedForTesting: Bool {
    state.withLock { $0.nativePlayerHandleReleased }
  }

  func withRenderer<T>(
    opaque: UnsafeMutableRawPointer,
    _ body: (PixelBufferRenderer) -> T
  ) -> T? {
    guard let entry = beginCallback() else { return nil }
    defer { endCallback(opaque: opaque) }
    guard let renderer = entry.displayRenderer else { return nil }
    return body(renderer)
  }

  /// Atomically hands an already-open vout's future display callbacks to a
  /// successor controller. Returns `false` only after permanent retirement
  /// or exact native-handle release.
  @discardableResult
  func setDisplayRenderer(_ renderer: PixelBufferRenderer?) -> Bool {
    state.withLock { state -> Bool in
      guard
        !state.retirementRequested,
        !state.nativePlayerHandleReleased,
        !state.opaqueRetainReleased
      else { return false }
      state.displayRenderer = renderer
      return true
    }
  }

  /// Creates the callback object for one negotiated vout. Every vout owns a
  /// separate decode renderer/pool, while display forwarding remains dynamic
  /// through this handle context so a successor PiPController can take over an
  /// already-open output.
  func makeVoutContext(
    handleOpaque: UnsafeMutableRawPointer,
    decodeRenderer: PixelBufferRenderer,
    sourceGeometry: PixelBufferSourceGeometry
  ) -> PixelBufferRendererVoutCallbackContext? {
    let accepted = state.withLock { state -> Bool in
      guard !state.nativePlayerHandleReleased, !state.opaqueRetainReleased else {
        return false
      }
      state.openVoutCount += 1
      return true
    }
    guard accepted else { return nil }
    return PixelBufferRendererVoutCallbackContext(
      handleContext: self,
      handleOpaque: handleOpaque,
      decodeRenderer: decodeRenderer,
      sourceGeometry: sourceGeometry
    )
  }

  func noteVoutClosed() {
    state.withLock {
      $0.openVoutCount = max(0, $0.openVoutCount - 1)
    }
  }

  /// Permanently removes the display target and suppresses future display
  /// work. Decode storage remains available to a vout that already copied the
  /// callbacks, and cleanup can still return its pool. In-flight callbacks
  /// retain their captured renderer(s) until they return. The opaque itself
  /// stays retained until
  /// `nativePlayerHandleDidRelease`, because an opening vout may have copied
  /// it before this retirement became visible.
  func requestRetirement() {
    state.withLock { state in
      state.retirementRequested = true
      state.displayRenderer = nil
    }
  }

  /// Called only after `libvlc_media_player_release` for the exact handle
  /// carrying this opaque has returned. No new callback can begin after this
  /// point. If a callback was already in flight, it performs the balancing
  /// release on exit.
  func nativePlayerHandleDidRelease(opaque: UnsafeMutableRawPointer) {
    let shouldRelease = state.withLock { state -> Bool in
      guard !state.opaqueRetainReleased else { return false }
      state.nativePlayerHandleReleased = true
      state.displayRenderer = nil
      guard state.activeCallbacks == 0 else { return false }
      state.opaqueRetainReleased = true
      return true
    }
    if shouldRelease {
      Unmanaged<PixelBufferRendererCallbackContext>.fromOpaque(opaque).release()
    }
  }

  private func beginCallback() -> CallbackEntry? {
    state.withLock { state -> CallbackEntry? in
      guard !state.opaqueRetainReleased else { return nil }
      state.activeCallbacks += 1
      return CallbackEntry(
        displayRenderer: state.displayRenderer
      )
    }
  }

  private func endCallback(opaque: UnsafeMutableRawPointer) {
    let shouldRelease = state.withLock { state -> Bool in
      state.activeCallbacks -= 1
      guard state.activeCallbacks == 0 else { return false }
      guard state.nativePlayerHandleReleased, !state.opaqueRetainReleased else { return false }
      state.opaqueRetainReleased = true
      return true
    }
    if shouldRelease {
      Unmanaged<PixelBufferRendererCallbackContext>.fromOpaque(opaque).release()
    }
  }
}

/// Callback storage owned by one exact pinned-vmem vout.
///
/// The media-player variables contain a handle-level context before setup.
/// The format callback replaces that vout's copied opaque with a retained
/// instance of this class. Its decode pool therefore cannot be replaced or
/// cleared by an overlapping vout, while display callbacks still consult the
/// handle context's current controller target.
final class PixelBufferRendererVoutCallbackContext: @unchecked Sendable {
  private struct PendingPicture: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let opaque: UnsafeMutableRawPointer
    var isLocked: Bool
  }

  private struct LifecycleState: @unchecked Sendable {
    var isCleaned = false
    var pendingPicture: PendingPicture?
  }

  let decodeRenderer: PixelBufferRenderer
  let sourceGeometry: PixelBufferSourceGeometry
  private let handleContext: PixelBufferRendererCallbackContext
  private let handleOpaque: UnsafeMutableRawPointer
  private let lifecycleState = Mutex(LifecycleState())

  init(
    handleContext: PixelBufferRendererCallbackContext,
    handleOpaque: UnsafeMutableRawPointer,
    decodeRenderer: PixelBufferRenderer,
    sourceGeometry: PixelBufferSourceGeometry
  ) {
    self.handleContext = handleContext
    self.handleOpaque = handleOpaque
    self.decodeRenderer = decodeRenderer
    self.sourceGeometry = sourceGeometry
  }

  func withDisplayRenderer<T>(
    _ body: (PixelBufferRenderer) -> T
  ) -> T? {
    handleContext.withRenderer(opaque: handleOpaque, body)
  }

  /// Pins one callback picture until display consumes it, a later lock
  /// supersedes it, or vout cleanup drains it. Pinned vmem exposes only one
  /// `pic_opaque` slot, so a second successful lock proves the predecessor can
  /// no longer be delivered by that vout. If a malformed callback sequence
  /// skipped unlock as well as display, drain also balances the Core Video
  /// base-address lock before releasing the final strong reference.
  func installPendingPicture(
    _ buffer: CVPixelBuffer,
    isLocked: Bool
  ) -> UnsafeMutableRawPointer? {
    let opaque = Unmanaged.passUnretained(buffer as AnyObject).toOpaque()
    let accepted = lifecycleState.withLock { state -> Bool in
      guard !state.isCleaned else { return false }
      drainPendingPicture(&state)
      state.pendingPicture = PendingPicture(
        buffer: buffer,
        opaque: opaque,
        isLocked: isLocked
      )
      return true
    }
    return accepted ? opaque : nil
  }

  /// Balances the base-address lock only for the currently owned picture.
  /// A stale unlock after replacement is ignored without dereferencing its
  /// potentially deallocated opaque pointer.
  func unlockPendingPicture(matching opaque: UnsafeMutableRawPointer) {
    lifecycleState.withLock { state in
      guard
        state.pendingPicture?.opaque == opaque,
        state.pendingPicture?.isLocked == true
      else { return }
      CVPixelBufferUnlockBaseAddress(state.pendingPicture!.buffer, [])
      state.pendingPicture!.isLocked = false
    }
  }

  /// Transfers the exact pending buffer to display. A duplicate or stale
  /// display callback observes no match and therefore cannot over-release or
  /// dereference an already-drained picture.
  func consumePendingPicture(
    matching opaque: UnsafeMutableRawPointer
  ) -> CVPixelBuffer? {
    lifecycleState.withLock { state -> CVPixelBuffer? in
      guard state.pendingPicture?.opaque == opaque else { return nil }
      if state.pendingPicture?.isLocked == true {
        CVPixelBufferUnlockBaseAddress(state.pendingPicture!.buffer, [])
      }
      let buffer = state.pendingPicture?.buffer
      state.pendingPicture = nil
      return buffer
    }
  }

  var hasPendingPictureForTesting: Bool {
    lifecycleState.withLock { $0.pendingPicture != nil }
  }

  func cleanupDecodeStorage() {
    let shouldClean = lifecycleState.withLock { state -> Bool in
      guard !state.isCleaned else { return false }
      state.isCleaned = true
      drainPendingPicture(&state)
      return true
    }
    guard shouldClean else { return }

    decodeRenderer.state.withLock {
      $0.pool = nil
      $0.width = 0
      $0.height = 0
      $0.renderPool = nil
      $0.renderPoolWidth = 0
      $0.renderPoolHeight = 0
      $0.advanceRenderGeneration()
    }
    handleContext.noteVoutClosed()
  }

  private func drainPendingPicture(_ state: inout LifecycleState) {
    guard let pending = state.pendingPicture else { return }
    if pending.isLocked {
      CVPixelBufferUnlockBaseAddress(pending.buffer, [])
    }
    state.pendingPicture = nil
  }
}

/// Class wrapper around `weak var layer` so the ObjC weak-reference
/// table sees a single stable address regardless of how `State` is
/// copied in and out of the surrounding `Mutex`.
final class DisplayLayerBox: @unchecked Sendable {
  weak var layer: AVSampleBufferDisplayLayer?
  init(_ layer: AVSampleBufferDisplayLayer?) {
    self.layer = layer
  }
}

// MARK: - Free Function Callbacks

func pixelBufferHandleCallbackContext(
  from opaque: UnsafeMutableRawPointer?
) -> PixelBufferRendererCallbackContext? {
  guard let opaque else { return nil }
  let object = Unmanaged<AnyObject>.fromOpaque(opaque).takeUnretainedValue()
  return object as? PixelBufferRendererCallbackContext
}

func pixelBufferVoutCallbackContext(
  from opaque: UnsafeMutableRawPointer?
) -> PixelBufferRendererVoutCallbackContext? {
  guard let opaque else { return nil }
  let object = Unmanaged<AnyObject>.fromOpaque(opaque).takeUnretainedValue()
  return object as? PixelBufferRendererVoutCallbackContext
}

/// Lock callback. Dequeues a `CVPixelBuffer` from the pool for libVLC to write into.
func pixelBufferLockCallback(
  opaque: UnsafeMutableRawPointer?,
  planes: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> UnsafeMutableRawPointer? {
  guard let opaque, let planes else { return nil }
  guard let context = pixelBufferVoutCallbackContext(from: opaque) else { return nil }

  let renderer = context.decodeRenderer
  let storage = renderer.state.withLock { ($0.pool, $0.width, $0.height) }
  guard let pool = storage.0 else { return nil }

  let allocation = pixelBufferRendererAllocatePixelBuffer(
    from: pool,
    width: storage.1,
    height: storage.2
  )
  guard allocation.status == kCVReturnSuccess, let pb = allocation.buffer else { return nil }

  let lockStatus = CVPixelBufferLockBaseAddress(pb, [])
  guard lockStatus == kCVReturnSuccess, let baseAddress = CVPixelBufferGetBaseAddress(pb) else {
    if lockStatus == kCVReturnSuccess {
      CVPixelBufferUnlockBaseAddress(pb, [])
    }
    return nil
  }

  guard let picture = context.installPendingPicture(pb, isLocked: true) else {
    CVPixelBufferUnlockBaseAddress(pb, [])
    return nil
  }
  planes[0] = baseAddress
  return picture
}

/// Unlock callback. Unlocks the `CVPixelBuffer` base address.
func pixelBufferUnlockCallback(
  opaque: UnsafeMutableRawPointer?,
  picture: UnsafeMutableRawPointer?,
  planes _: UnsafePointer<UnsafeMutableRawPointer?>?
) {
  guard
    let picture,
    let context = pixelBufferVoutCallbackContext(from: opaque)
  else { return }
  context.unlockPendingPicture(matching: picture)
}

/// Display callback. Wraps the `CVPixelBuffer` in a `CMSampleBuffer`
/// and enqueues it onto the `AVSampleBufferDisplayLayer`.
func pixelBufferDisplayCallback(
  opaque: UnsafeMutableRawPointer?,
  picture: UnsafeMutableRawPointer?
) {
  guard
    let picture,
    let context = pixelBufferVoutCallbackContext(from: opaque),
    let pb = context.consumePendingPicture(matching: picture)
  else { return }

  _ = context.withDisplayRenderer { renderer in
    guard let output = renderer.outputPixelBuffer(from: pb) else { return }
    let outputBuffer = output.buffer
    let renderGeneration = output.generation

    let (timebase, layer) = renderer.state.withLock { ($0.timebase, $0.displayLayer.layer) }

    guard let layer else { return }
    guard
      let desc = renderer.formatDescription(
        for: outputBuffer,
        generation: renderGeneration
      )
    else { return }

    let pts: CMTime = if let timebase {
      CMTimebaseGetTime(timebase)
    } else {
      CMClockGetTime(CMClockGetHostTimeClock())
    }

    // When the control timebase is frozen (rate 0, i.e. paused), its time
    // does not advance, so a seek-while-paused frame carries a PTS no later
    // than the already-presented one and the layer may never schedule it.
    // Flag such frames for immediate display so paused scrubbing repaints.
    // Steady-state playback (rate != 0, or no timebase) stays timebase- or
    // host-clock-paced.
    let displayImmediately = timebase.map { CMTimebaseGetRate($0) == 0 } ?? false

    var timingInfo = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: pts,
      decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: outputBuffer,
      formatDescription: desc,
      sampleTiming: &timingInfo,
      sampleBufferOut: &sampleBuffer
    )
    guard sbStatus == noErr, let sb = sampleBuffer else { return }
    if
      displayImmediately,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sb,
        createIfNecessary: true
      ) as? [NSMutableDictionary], let attachment = attachments.first {
      attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
    }
    // CMSampleBuffer is a CF type that lacks Sendable conformance but is thread-safe for read access
    nonisolated(unsafe) let sample = sb
    renderer.enqueue(sample, generation: renderGeneration, on: layer)
  }
}

/// Cleanup callback. Releases the pixel buffer pool.
func pixelBufferCleanupCallback(opaque: UnsafeMutableRawPointer?) {
  guard
    let opaque,
    let context = pixelBufferVoutCallbackContext(from: opaque)
  else { return }

  context.cleanupDecodeStorage()
  // Balance the per-vout retain installed by the successful format callback.
  Unmanaged<PixelBufferRendererVoutCallbackContext>.fromOpaque(opaque).release()
}

#endif
