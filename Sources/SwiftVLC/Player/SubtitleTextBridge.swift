import CLibVLC
import Synchronization

/// The native operations behind text-subtitle capture.
///
/// Keeping these calls injectable lets the callback bridge and the `Player`
/// lifecycle be tested with the released libVLC artifact, which deliberately
/// does not export SwiftVLC's subtitle callback extension.
struct SubtitleTextNativeOperations {
  typealias Registration = @MainActor @Sendable (
    OpaquePointer,
    swiftvlc_subtitle_text_snapshot_cb,
    UnsafeMutableRawPointer
  ) -> Bool

  let isAvailable: @MainActor @Sendable () -> Bool
  let register: Registration

  static let live = Self(
    isAvailable: {
      swiftvlc_subtitle_text_snapshot_callback_available()
    },
    register: { player, callback, opaque in
      swiftvlc_media_player_set_subtitle_text_snapshot_callback_if_available(
        player,
        callback,
        opaque
      )
    }
  )
}

/// A thread-safe, generation-scoped source of the text subtitle regions
/// currently on screen.
///
/// libVLC owns the callback thread. The callback copies every UTF-8 string and
/// placement value before returning, then this bridge fans the resulting
/// ``TextSubtitleSnapshot`` out through independent newest-one streams. A
/// native handle replacement commits a new immutable callback generation;
/// callbacks that race in from a retiring handle are ignored.
final class SubtitleTextBridge: Sendable {
  typealias Registration = (
    swiftvlc_subtitle_text_snapshot_cb,
    UnsafeMutableRawPointer
  ) -> Bool

  private struct PendingSnapshot {
    var latest: TextSubtitleSnapshot?
  }

  private struct State {
    var nextGeneration: UInt64 = 0
    var currentGeneration: UInt64?
    // A native setter may synchronously invoke the candidate callback before
    // its generation commits. The candidate is not yet observable, so retain
    // only its newest complete snapshot rather than an unbounded backlog.
    var pendingSnapshots: [UInt64: PendingSnapshot] = [:]
    var latest = TextSubtitleSnapshot()
    var isAwaitingNativeClear = false
    var isTerminated = false
  }

  private let state = Mutex(State())
  private let broadcaster = Broadcaster<TextSubtitleSnapshot>(defaultBufferSize: 1)

  init() {
    // A subscriber must always know whether anything is displayed. Seeding
    // the replay cache here makes the initial answer deterministic without a
    // separate property read that could race the first callback.
    broadcaster.broadcast(TextSubtitleSnapshot())
  }

  /// Creates an independent, newest-one stream that begins with the current
  /// snapshot (initially an empty region array).
  func subscribe(
    policy: EventBufferingPolicy = .newest(1)
  ) -> AsyncStream<TextSubtitleSnapshot> {
    broadcaster.subscribeReplayingLatest(policy: policy)
  }

  /// Installs one immutable callback attachment on an exact native handle.
  ///
  /// The registration is committed only after the native setter succeeds, so
  /// a rejected candidate handle leaves the outgoing handle authoritative.
  /// `NativePlayerHandleLifetime` retains the callback opaque until every
  /// native owner has released that exact handle, including the offloaded
  /// release initiated by `Player.deinit`.
  func attach(
    to lifetime: NativePlayerHandleLifetime,
    using registration: Registration
  ) -> Bool {
    guard !lifetime.isReleased else { return false }

    guard
      let generation = state.withLock({ state -> UInt64? in
        guard !state.isTerminated else { return nil }
        state.nextGeneration &+= 1
        let generation = state.nextGeneration
        state.pendingSnapshots[generation] = PendingSnapshot()
        return generation
      }) else { return false }

    let attachment = SubtitleTextCallbackAttachment(
      bridge: self,
      generation: generation
    )
    let opaque = Unmanaged.passUnretained(attachment).toOpaque()
    guard registration(swiftVLCSubtitleTextCallback, opaque) else {
      _ = state.withLock {
        $0.pendingSnapshots.removeValue(forKey: generation)
      }
      return false
    }

    // Registration latches the opaque into the native handle. Establish its
    // lifetime before publishing the generation as current.
    lifetime.retainUntilReleased([attachment])

    return state.withLock { state in
      guard !state.isTerminated else {
        state.pendingSnapshots.removeValue(forKey: generation)
        return false
      }
      let pendingSnapshot = state.pendingSnapshots.removeValue(forKey: generation)
      // Termination is the only operation that can remove a pending entry,
      // and that state was handled above while holding this same lock.
      precondition(pendingSnapshot != nil)
      if let currentGeneration = state.currentGeneration {
        guard generation > currentGeneration else { return false }
      }
      state.currentGeneration = generation
      state.isAwaitingNativeClear = false
      if !state.latest.isEmpty {
        state.latest = TextSubtitleSnapshot()
        broadcaster.broadcast(TextSubtitleSnapshot())
      }
      if let snapshot = pendingSnapshot?.latest, state.latest != snapshot {
        state.latest = snapshot
        broadcaster.broadcast(snapshot)
      }
      return true
    }
  }

  /// Clears the current presentation without ending any subscriptions.
  func reset(awaitingNativeClear: Bool = false) {
    state.withLock { state in
      guard !state.isTerminated else { return }
      if awaitingNativeClear {
        // A cue callback already in flight on this same native handle can
        // reach Swift after a media/terminal reset. The engine emits an
        // ordered empty callback when that live subtitle output detaches;
        // until it arrives, reject nonempty callbacks so a retiring cue cannot
        // repopulate the overlay. Callers only request this barrier while a
        // native output is live, so initial/historical-idle loads cannot wait
        // forever for a clear that will never be produced.
        state.isAwaitingNativeClear = true
      }
      if !state.latest.isEmpty {
        state.latest = TextSubtitleSnapshot()
        broadcaster.broadcast(TextSubtitleSnapshot())
      }
    }
  }

  /// Permanently finishes existing and future subscriptions.
  func terminate() {
    state.withLock { state in
      guard !state.isTerminated else { return }
      if !state.latest.isEmpty {
        state.latest = TextSubtitleSnapshot()
        broadcaster.broadcast(TextSubtitleSnapshot())
      }
      state.isTerminated = true
      state.currentGeneration = nil
      state.pendingSnapshots.removeAll()
      state.isAwaitingNativeClear = false
      broadcaster.terminate()
    }
  }

  fileprivate func receive(_ snapshot: TextSubtitleSnapshot, generation: UInt64) {
    state.withLock { state in
      guard !state.isTerminated else { return }
      guard state.currentGeneration == generation else {
        guard var pendingSnapshot = state.pendingSnapshots[generation] else { return }
        pendingSnapshot.latest = snapshot
        state.pendingSnapshots[generation] = pendingSnapshot
        return
      }

      if state.isAwaitingNativeClear {
        guard snapshot.isEmpty else { return }
        state.isAwaitingNativeClear = false
        return
      }
      guard state.latest != snapshot else { return }
      state.latest = snapshot
      broadcaster.broadcast(snapshot)
    }
  }
}

/// The object represented by libVLC's unretained callback opaque.
///
/// The bridge reference is weak to avoid `Player -> bridge -> attachment ->
/// bridge`. The native-handle lifetime, not the bridge, owns the attachment.
private final class SubtitleTextCallbackAttachment: @unchecked Sendable {
  private weak var bridge: SubtitleTextBridge?
  private let generation: UInt64

  init(bridge: SubtitleTextBridge, generation: UInt64) {
    self.bridge = bridge
    self.generation = generation
  }

  func receive(
    _ regions: UnsafePointer<swiftvlc_subtitle_text_region_t>?,
    count: Int
  ) {
    // Native pointers are valid only for this callback. Copy all text and
    // placement fields synchronously so no borrowed memory escapes to a task.
    let snapshot = Self.copySnapshot(regions, count: count)
    bridge?.receive(snapshot, generation: generation)
  }

  private static func copySnapshot(
    _ regions: UnsafePointer<swiftvlc_subtitle_text_region_t>?,
    count: Int
  ) -> TextSubtitleSnapshot {
    guard count > 0, let regions else {
      return TextSubtitleSnapshot()
    }

    let copiedRegions = UnsafeBufferPointer(start: regions, count: count).map { region in
      TextSubtitleRegion(
        text: region.text.map(String.init(cString:)) ?? "",
        placement: copyPlacement(region)
      )
    }
    return TextSubtitleSnapshot(regions: copiedRegions)
  }

  private static func copyPlacement(
    _ region: swiftvlc_subtitle_text_region_t
  ) -> TextSubtitlePlacement {
    guard
      region.placement == UInt32(
        truncatingIfNeeded: swiftvlc_subtitle_text_placement_webvtt
      ),
      let placement = copyWebVTTPlacement(region.webvtt)
    else {
      // Provenance is explicit. Unknown discriminators and malformed WebVTT
      // payloads fail closed instead of inferring a format from geometry.
      return .automatic
    }
    return .webVTT(placement)
  }

  private static func copyWebVTTPlacement(
    _ native: swiftvlc_webvtt_placement_t
  ) -> WebVTTPlacement? {
    let hasMaximumWidth = UInt32(
      truncatingIfNeeded: SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_WIDTH
    )
    let hasMaximumHeight = UInt32(
      truncatingIfNeeded: SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_HEIGHT
    )
    let knownFlags = hasMaximumWidth | hasMaximumHeight
    guard native.flags & ~knownFlags == 0 else { return nil }

    let maximumWidth = native.flags & hasMaximumWidth == 0
      ? nil
      : native.maximum_width
    let maximumHeight = native.flags & hasMaximumHeight == 0
      ? nil
      : native.maximum_height

    guard
      native.horizontal_position.isFinite,
      native.vertical_position.isFinite,
      maximumWidth?.isFinite ?? true,
      maximumHeight?.isFinite ?? true,
      maximumWidth.map({ $0 >= 0 }) ?? true,
      maximumHeight.map({ $0 >= 0 }) ?? true,
      let horizontalAnchor = horizontalAnchor(native.horizontal_anchor),
      let verticalAnchor = verticalAnchor(native.vertical_anchor),
      let textAlignment = textAlignment(native.text_alignment),
      let writingDirection = writingDirection(native.writing_direction)
    else { return nil }

    return WebVTTPlacement(
      horizontalPosition: native.horizontal_position,
      verticalPosition: native.vertical_position,
      horizontalAnchor: horizontalAnchor,
      verticalAnchor: verticalAnchor,
      maximumWidth: maximumWidth,
      maximumHeight: maximumHeight,
      textAlignment: textAlignment,
      writingDirection: writingDirection
    )
  }

  private static func horizontalAnchor(
    _ value: swiftvlc_webvtt_horizontal_anchor_t
  ) -> WebVTTPlacement.HorizontalAnchor? {
    if value == UInt32(truncatingIfNeeded: swiftvlc_webvtt_horizontal_anchor_center) {
      return .center
    }
    if value == UInt32(truncatingIfNeeded: swiftvlc_webvtt_horizontal_anchor_left) {
      return .left
    }
    if value == UInt32(truncatingIfNeeded: swiftvlc_webvtt_horizontal_anchor_right) {
      return .right
    }
    return nil
  }

  private static func verticalAnchor(
    _ value: swiftvlc_webvtt_vertical_anchor_t
  ) -> WebVTTPlacement.VerticalAnchor? {
    if value == UInt32(truncatingIfNeeded: swiftvlc_webvtt_vertical_anchor_center) {
      return .center
    }
    if value == UInt32(truncatingIfNeeded: swiftvlc_webvtt_vertical_anchor_top) {
      return .top
    }
    if value == UInt32(truncatingIfNeeded: swiftvlc_webvtt_vertical_anchor_bottom) {
      return .bottom
    }
    return nil
  }

  private static func textAlignment(
    _ value: swiftvlc_webvtt_text_alignment_t
  ) -> WebVTTPlacement.TextAlignment? {
    if value == UInt32(truncatingIfNeeded: swiftvlc_webvtt_text_alignment_center) {
      return .center
    }
    if value == UInt32(truncatingIfNeeded: swiftvlc_webvtt_text_alignment_left) {
      return .left
    }
    if value == UInt32(truncatingIfNeeded: swiftvlc_webvtt_text_alignment_right) {
      return .right
    }
    return nil
  }

  private static func writingDirection(
    _ value: swiftvlc_webvtt_writing_direction_t
  ) -> WebVTTPlacement.WritingDirection? {
    if value == UInt32(truncatingIfNeeded: swiftvlc_webvtt_writing_direction_horizontal) {
      return .horizontal
    }
    if
      value == UInt32(
        truncatingIfNeeded: swiftvlc_webvtt_writing_direction_vertical_growing_left
      ) {
      return .verticalGrowingLeft
    }
    if
      value == UInt32(
        truncatingIfNeeded: swiftvlc_webvtt_writing_direction_vertical_growing_right
      ) {
      return .verticalGrowingRight
    }
    return nil
  }
}

private func swiftVLCSubtitleTextCallback(
  _ opaque: UnsafeMutableRawPointer?,
  _ regions: UnsafePointer<swiftvlc_subtitle_text_region_t>?,
  _ regionCount: Int
) {
  guard let opaque else { return }
  Unmanaged<SubtitleTextCallbackAttachment>
    .fromOpaque(opaque)
    .takeUnretainedValue()
    .receive(regions, count: regionCount)
}
