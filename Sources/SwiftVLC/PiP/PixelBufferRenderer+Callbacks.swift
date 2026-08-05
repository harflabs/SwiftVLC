#if os(iOS) || os(macOS)
import AVFoundation
import CLibVLC
import CoreMedia
import CoreVideo
import Foundation
import os
import Synchronization

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
    playbackGeneration: UInt64 = 0,
    voutGenerationCounter: PixelBufferVoutGenerationCounter = PixelBufferVoutGenerationCounter(),
    api: DirectPiPVideoCallbackAPI
  ) {
    precondition(!lifetime.isReleased)
    self.lifetime = lifetime
    self.api = api
    let context = PixelBufferRendererCallbackContext(
      renderer: decodeRenderer,
      playbackGeneration: playbackGeneration,
      voutGenerationCounter: voutGenerationCounter
    )
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
  private let playbackGeneration: @Sendable () -> UInt64
  private var current: Binding?

  init(
    renderer: PixelBufferRenderer,
    playbackGeneration: @escaping @Sendable () -> UInt64 = { 0 },
    api: DirectPiPVideoCallbackAPI = .live
  ) {
    self.renderer = renderer
    self.playbackGeneration = playbackGeneration
    self.api = api
  }

  func makeSlot(on lifetime: NativePlayerHandleLifetime) -> DirectPiPVideoCallbackSlot {
    DirectPiPVideoCallbackSlot(
      lifetime: lifetime,
      decodeRenderer: renderer,
      playbackGeneration: playbackGeneration(),
      voutGenerationCounter: current?.slot.context.voutGenerationSequence
        ?? PixelBufferVoutGenerationCounter(),
      api: api
    )
  }

  func bind(to slot: DirectPiPVideoCallbackSlot, generation: UInt64) {
    let playbackGeneration = playbackGeneration()
    slot.context.beginPlaybackGeneration(playbackGeneration)
    renderer.beginPlaybackGeneration(playbackGeneration)
    slot.activate(renderer: renderer)
    slot.context.setQualificationTelemetryEnabled(
      renderer.contentDiagnosticsEnabled.load(ordering: .acquiring)
    )
    slot.context.setPresentationCopyRequired(
      renderer.presentationCopyEnabled.load(ordering: .acquiring)
    )
    current = Binding(slot: slot, generation: generation)
  }

  func setQualificationTelemetryEnabled(_ enabled: Bool) {
    current?.slot.context.setQualificationTelemetryEnabled(enabled)
  }

  func setPresentationCopyRequired(_ required: Bool) {
    current?.slot.context.setPresentationCopyRequired(required)
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

  var telemetrySnapshot: PixelBufferRendererTelemetrySnapshot {
    renderer.telemetrySnapshot
  }

  var sourceDeliverySnapshot: PixelBufferVoutSourceSnapshot? {
    current?.slot.context.latestSourceDeliverySnapshot
  }

  func beginPlaybackGeneration(_ generation: UInt64) {
    current?.slot.context.beginPlaybackGeneration(generation)
    renderer.beginPlaybackGeneration(generation)
  }
}

struct PixelBufferVoutSourceSnapshot: Sendable, Equatable {
  let voutGeneration: UInt64
  let width: Int
  let height: Int
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
    var sourceDeliveryByVoutGeneration: [UInt64: PixelBufferVoutSourceSnapshot] = [:]
    var retirementRequested = false
    var nativePlayerHandleReleased = false
    var opaqueRetainReleased = false
  }

  private let state: Mutex<State>
  private let presentationCopyRequired: Atomic<Bool>
  private let qualificationTelemetryEnabled: Atomic<Bool>
  private let playbackGeneration: Mutex<UInt64>
  private let voutGenerationCounter: PixelBufferVoutGenerationCounter

  init(
    renderer: PixelBufferRenderer,
    playbackGeneration: UInt64 = 0,
    voutGenerationCounter: PixelBufferVoutGenerationCounter = PixelBufferVoutGenerationCounter()
  ) {
    state = Mutex(State(displayRenderer: renderer))
    presentationCopyRequired = Atomic(
      renderer.presentationCopyEnabled.load(ordering: .acquiring)
    )
    qualificationTelemetryEnabled = Atomic(
      renderer.contentDiagnosticsEnabled.load(ordering: .acquiring)
    )
    self.playbackGeneration = Mutex(playbackGeneration)
    self.voutGenerationCounter = voutGenerationCounter
  }

  /// Advances the generation captured by subsequently negotiated vouts.
  /// Already-open vouts retain their original value and are therefore rejected
  /// by the display renderer after a media boundary.
  func beginPlaybackGeneration(_ generation: UInt64) {
    playbackGeneration.withLock { $0 = generation }
  }

  var hasOpenVoutForTesting: Bool {
    state.withLock { $0.openVoutCount > 0 }
  }

  var voutGenerationSequence: PixelBufferVoutGenerationCounter {
    voutGenerationCounter
  }

  var latestSourceDeliverySnapshot: PixelBufferVoutSourceSnapshot? {
    state.withLock { state in
      state.sourceDeliveryByVoutGeneration.max { lhs, rhs in
        lhs.key < rhs.key
      }?.value
    }
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

  func setQualificationTelemetryEnabled(_ enabled: Bool) {
    qualificationTelemetryEnabled.store(enabled, ordering: .releasing)
  }

  var isQualificationTelemetryEnabled: Bool {
    qualificationTelemetryEnabled.load(ordering: .acquiring)
  }

  func setPresentationCopyRequired(_ required: Bool) {
    presentationCopyRequired.store(required, ordering: .releasing)
  }

  var isPresentationCopyRequired: Bool {
    presentationCopyRequired.load(ordering: .acquiring)
  }

  /// Atomically hands an already-open vout's future display callbacks to a
  /// successor controller. Returns `false` only after permanent retirement
  /// or exact native-handle release.
  @discardableResult
  func setDisplayRenderer(_ renderer: PixelBufferRenderer?) -> Bool {
    let accepted = state.withLock { state -> Bool in
      guard
        !state.retirementRequested,
        !state.nativePlayerHandleReleased,
        !state.opaqueRetainReleased
      else { return false }
      state.displayRenderer = renderer
      return true
    }
    if accepted {
      setPresentationCopyRequired(
        renderer?.presentationCopyEnabled.load(ordering: .acquiring) ?? false
      )
      setQualificationTelemetryEnabled(
        renderer?.contentDiagnosticsEnabled.load(ordering: .acquiring) ?? false
      )
    }
    return accepted
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
    let voutGeneration = voutGenerationCounter.next()
    let sourceDelivery = decodeRenderer.state.withLock {
      PixelBufferVoutSourceSnapshot(
        voutGeneration: voutGeneration,
        width: $0.width,
        height: $0.height
      )
    }
    let accepted = state.withLock { state -> Bool in
      guard !state.nativePlayerHandleReleased, !state.opaqueRetainReleased else {
        return false
      }
      state.openVoutCount += 1
      state.sourceDeliveryByVoutGeneration[voutGeneration] = sourceDelivery
      return true
    }
    guard accepted else { return nil }
    return PixelBufferRendererVoutCallbackContext(
      handleContext: self,
      handleOpaque: handleOpaque,
      decodeRenderer: decodeRenderer,
      sourceGeometry: sourceGeometry,
      playbackGeneration: playbackGeneration.withLock { $0 },
      voutGeneration: voutGeneration
    )
  }

  func noteVoutClosed(voutGeneration: UInt64) {
    state.withLock {
      $0.openVoutCount = max(0, $0.openVoutCount - 1)
      $0.sourceDeliveryByVoutGeneration.removeValue(forKey: voutGeneration)
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
    let playbackGeneration: UInt64
  }

  private struct LifecycleState: @unchecked Sendable {
    var isCleaned = false
    var pendingPicture: PendingPicture?
  }

  let decodeRenderer: PixelBufferRenderer
  let sourceGeometry: PixelBufferSourceGeometry
  let voutGeneration: UInt64
  private let handleContext: PixelBufferRendererCallbackContext
  private let handleOpaque: UnsafeMutableRawPointer
  private let lifecycleState = Mutex(LifecycleState())
  private let playbackGeneration: UInt64

  init(
    handleContext: PixelBufferRendererCallbackContext,
    handleOpaque: UnsafeMutableRawPointer,
    decodeRenderer: PixelBufferRenderer,
    sourceGeometry: PixelBufferSourceGeometry,
    playbackGeneration: UInt64,
    voutGeneration: UInt64
  ) {
    self.handleContext = handleContext
    self.handleOpaque = handleOpaque
    self.decodeRenderer = decodeRenderer
    self.sourceGeometry = sourceGeometry
    self.playbackGeneration = playbackGeneration
    self.voutGeneration = voutGeneration
  }

  func withDisplayRenderer<T>(
    _ body: (PixelBufferRenderer) -> T
  ) -> T? {
    handleContext.withRenderer(opaque: handleOpaque, body)
  }

  /// Records callback-path telemetry only when the active qualification
  /// renderer explicitly enabled content diagnostics. Normal clients do not
  /// take an extra renderer-state lock on every vmem callback.
  func recordQualificationCallback(
    _ update: (inout PixelBufferRenderer.State) -> Void
  ) {
    guard handleContext.isQualificationTelemetryEnabled else { return }
    _ = withDisplayRenderer { renderer in
      renderer.state.withLock { state in
        update(&state)
      }
    }
  }

  var isPresentationCopyRequired: Bool {
    handleContext.isPresentationCopyRequired
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
        isLocked: isLocked,
        playbackGeneration: playbackGeneration
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
  ) -> (buffer: CVPixelBuffer, playbackGeneration: UInt64)? {
    lifecycleState.withLock { state -> (CVPixelBuffer, UInt64)? in
      guard state.pendingPicture?.opaque == opaque else { return nil }
      if state.pendingPicture?.isLocked == true {
        CVPixelBufferUnlockBaseAddress(state.pendingPicture!.buffer, [])
      }
      guard let pending = state.pendingPicture else { return nil }
      state.pendingPicture = nil
      return (pending.buffer, pending.playbackGeneration)
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
    handleContext.noteVoutClosed(voutGeneration: voutGeneration)
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
  context.recordQualificationCallback { $0.vmemLockAttemptCount &+= 1 }
  let storage = renderer.state.withLock { ($0.pool, $0.width, $0.height) }
  guard let pool = storage.0 else {
    context.recordQualificationCallback { $0.vmemPoolUnavailableCount &+= 1 }
    return nil
  }

  let allocation = pixelBufferRendererAllocatePixelBuffer(
    from: pool,
    width: storage.1,
    height: storage.2,
    additionalAllocationHeadroom: context.isPresentationCopyRequired ? 1 : 0
  )
  guard allocation.status == kCVReturnSuccess, let pb = allocation.buffer else {
    context.recordQualificationCallback {
      $0.decodePoolAllocationFailureCount &+= 1
      $0.lastDecodePoolAllocationStatus = allocation.status
    }
    return nil
  }

  let lockStatus = CVPixelBufferLockBaseAddress(pb, [])
  guard lockStatus == kCVReturnSuccess, let baseAddress = CVPixelBufferGetBaseAddress(pb) else {
    context.recordQualificationCallback { $0.vmemBaseAddressLockFailureCount &+= 1 }
    if lockStatus == kCVReturnSuccess {
      CVPixelBufferUnlockBaseAddress(pb, [])
    }
    return nil
  }

  guard let picture = context.installPendingPicture(pb, isLocked: true) else {
    context.recordQualificationCallback { $0.vmemPendingInstallFailureCount &+= 1 }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return nil
  }
  context.recordQualificationCallback { $0.vmemLockSuccessCount &+= 1 }
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
  context.recordQualificationCallback { $0.vmemUnlockCallbackCount &+= 1 }
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
    let context = pixelBufferVoutCallbackContext(from: opaque)
  else { return }
  context.recordQualificationCallback { $0.vmemDisplayCallbackCount &+= 1 }
  guard let consumed = context.consumePendingPicture(matching: picture) else {
    context.recordQualificationCallback { $0.vmemDisplayConsumeFailureCount &+= 1 }
    return
  }

  let pb = consumed.buffer
  let playbackGeneration = consumed.playbackGeneration

  _ = context.withDisplayRenderer { renderer in
    let acceptsPlaybackGeneration = renderer.state.withLock {
      $0.playbackGeneration == playbackGeneration
    }
    guard acceptsPlaybackGeneration else { return }
    renderer.state.withLock {
      $0.decodedFrameCount &+= 1
      $0.lastDecodedAt = .now
    }
    guard let output = renderer.outputPixelBuffer(from: pb) else { return }
    let outputBuffer = output.buffer
    let renderGeneration = output.generation
    renderer.recordContentFingerprintIfEnabled(of: outputBuffer)

    let (timebase, layer) = renderer.state.withLock {
      ($0.timebase, $0.displayLayer.layer)
    }

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
      // vmem does not expose this source frame's duration. A track's reported
      // ratio may be nominal/average for VFR, so any constant would fabricate
      // timing; the presentation timestamp remains authoritative.
      duration: PixelBufferRenderer.sampleDuration,
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
    renderer.enqueue(
      sample,
      generation: renderGeneration,
      on: layer,
      playbackGeneration: playbackGeneration,
      voutGeneration: context.voutGeneration
    )
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
