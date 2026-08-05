#if os(iOS)

import AVKit
import CoreMedia
import Synchronization

/// A snapshot of libVLC's private native PiP machinery on iOS.
///
/// This is intentionally SPI, not stable public API. It exists for the
/// in-repo Showcase device-validation harness, which records how the
/// pinned libVLC binary wires its PiP window controller and
/// `AVPictureInPictureController` delegate. The shape of the probed
/// surface may change with any libVLC pin, and this type may change or
/// disappear with it, outside SwiftVLC's public semantic-versioning
/// contract.
@_spi(ValidationHarness)
public struct NativePiPProbe: Sendable {
  /// Runtime class name of libVLC's PiP window controller, if one has
  /// been handed over via the PiP-ready callback.
  public let windowControllerClassName: String?

  /// Whether the window controller exposed an
  /// `AVPictureInPictureController` through its `avPipController` key.
  public let hasAVController: Bool

  /// Runtime class name of the `AVPictureInPictureController`'s
  /// original libVLC delegate, if any.
  public let avDelegateClassName: String?

  /// Whether SwiftVLC successfully installed its lifecycle-forwarding bridge
  /// in front of libVLC's delegate.
  public let hasLifecycleDelegateBridge: Bool

  /// `respondsToSelector` results for the
  /// `AVPictureInPictureControllerDelegate` callbacks, keyed by
  /// selector name. Empty when no delegate is installed.
  public let delegateResponds: [String: Bool]

  /// The native backend's current possible flag.
  public let isPossible: Bool

  /// The native backend's current active flag.
  public let isActive: Bool
}

/// The transport policy SwiftVLC most recently applied to AVKit.
///
/// This is qualification SPI rather than public API. It lets the in-repo
/// physical-device lane prove that an indefinite live input actually reached
/// AVKit as an unbounded, linear-playback timeline instead of inferring that
/// policy from a working video window.
@_spi(Qualification)
public struct PiPPlaybackQualificationSnapshot: Sendable, Equatable {
  /// Whether AVKit's skip and scrub controls are disabled for this input.
  public let requiresLinearPlayback: Bool
  /// The duration last published to AVKit, or `nil` for an unbounded range.
  public let durationMilliseconds: Int64?
  /// Whether the current input was published as seekable.
  public let isSeekable: Bool
}

/// One atomic engine query used to prove native PiP never combines playback
/// values from different media generations during replacement.
@_spi(Qualification)
public struct NativePiPPlaybackQualificationSnapshot: Sendable, Equatable {
  public let mediaGeneration: UInt64
  public let durationMilliseconds: Int64
  public let currentTimeMilliseconds: Int64
  public let isSeekable: Bool
}

/// State from the qualification-only fault injector that drops raw libVLC
/// length and seekability callbacks while preserving native polling.
@_spi(Qualification)
public struct RawCapabilityEventSuppressionSnapshot: Sendable, Equatable {
  public let isEnabled: Bool
  public let suppressedLengthEventCount: Int
  public let suppressedSeekableEventCount: Int
}

/// Deterministic native-pause capability fault used by the physical
/// deferred-pause qualification lane.
@_spi(Qualification)
public enum DeferredPauseQualificationFault: Sendable, Equatable {
  /// Restore the live libVLC capability probe and clear prior counters.
  case disabled
  /// Reject every native pause probe until explicitly disabled.
  case permanentRejection
  /// Reject a fixed number of probes, then return authority to libVLC.
  case transientRejection(attempts: Int)
}

/// Counters captured from the live Player pause path while qualification fault
/// injection is enabled.
@_spi(Qualification)
public struct DeferredPauseQualificationSnapshot: Sendable, Equatable {
  public let isEnabled: Bool
  public let forcedRejectionCount: Int
  public let nativePauseCommandCount: Int
  public let remainingTransientRejections: Int
}

/// Direct-renderer counters used by the physical performance lane.
///
/// This is qualification SPI: the values describe internal conversion work
/// and are deliberately not a source-compatible public diagnostics API.
@_spi(Qualification)
public struct PiPRenderPerformanceSnapshot: Sendable, Equatable {
  public let sourceWidth: Int
  public let sourceHeight: Int
  public let targetWidth: Int?
  public let targetHeight: Int?
  public let renderPoolWidth: Int
  public let renderPoolHeight: Int
  public let renderGeneration: UInt64
  public let displayLayerFlushes: UInt64
  public let presentationCopyFrames: UInt64
  public let presentationCopyFailures: UInt64
  public let measuredConversionCount: UInt64
  public let measuredConversionNanoseconds: UInt64
  public let maximumMeasuredConversionNanoseconds: UInt64
  public let decodedFrames: UInt64
  public let decodedContentChanges: UInt64
  public let callbackAttempts: UInt64
  public let callbackSuccesses: UInt64
  public let displayCallbacks: UInt64
  public let displayConsumeFailures: UInt64
  public let renderPoolAllocationFailureCount: UInt64
  public let lastRenderPoolAllocationStatus: Int32?
  public let deliveredFrameCount: UInt64
  public let droppedFrameCount: UInt64
}

extension PlaybackGeneration {
  /// Numeric form used only for machine-readable qualification evidence.
  @_spi(Qualification)
  public var qualificationValue: UInt64 {
    value
  }
}

extension PiPController {
  /// Captures the direct renderer's actual source and conversion geometry plus
  /// cumulative callback counters. A native controller returns `nil` because
  /// libVLC owns that renderer and these counters would describe an unused
  /// sample-buffer path.
  @_spi(Qualification)
  public var renderPerformanceQualificationSnapshot: PiPRenderPerformanceSnapshot? {
    guard nativeBackend == nil else { return nil }
    let source = callbackRegistration?.sourceDeliverySnapshot
    let telemetry = callbackRegistration?.telemetrySnapshot ?? renderer.telemetrySnapshot
    return renderer.state.withLock { state in
      PiPRenderPerformanceSnapshot(
        sourceWidth: source?.width ?? 0,
        sourceHeight: source?.height ?? 0,
        targetWidth: state.renderSize.map { Int($0.width) },
        targetHeight: state.renderSize.map { Int($0.height) },
        renderPoolWidth: state.renderPoolWidth,
        renderPoolHeight: state.renderPoolHeight,
        renderGeneration: state.renderGeneration,
        displayLayerFlushes: state.displayLayerFlushRequestCount,
        presentationCopyFrames: state.presentationCopyFrameCount,
        presentationCopyFailures: state.presentationCopyFailureCount,
        measuredConversionCount: state.measuredConversionCount,
        measuredConversionNanoseconds: state.measuredConversionNanoseconds,
        maximumMeasuredConversionNanoseconds: state.maximumMeasuredConversionNanoseconds,
        decodedFrames: state.decodedFrameCount,
        decodedContentChanges: state.decodedContentChangeCount,
        callbackAttempts: state.vmemLockAttemptCount,
        callbackSuccesses: state.vmemLockSuccessCount,
        displayCallbacks: state.vmemDisplayCallbackCount,
        displayConsumeFailures: telemetry.vmemDisplayConsumeFailureCount,
        renderPoolAllocationFailureCount: telemetry.renderPoolAllocationFailureCount,
        lastRenderPoolAllocationStatus: telemetry.lastRenderPoolAllocationStatus,
        deliveredFrameCount: telemetry.presentedFrameCount,
        droppedFrameCount: telemetry.droppedFrameCount
      )
    }
  }

  /// Starts a new direct-conversion measurement window without disturbing the
  /// decoded-content counters used by the same physical qualification row.
  @_spi(Qualification)
  public func resetRenderPerformanceQualificationMeasurements() {
    guard nativeBackend == nil else { return }
    renderer.state.withLock { state in
      state.measuredConversionCount = 0
      state.measuredConversionNanoseconds = 0
      state.maximumMeasuredConversionNanoseconds = 0
    }
  }

  /// The AVKit-controller identity that qualification lifecycle envelopes use.
  @_spi(Qualification)
  public var qualificationControllerGeneration: UInt64 {
    pipControllerGeneration
  }

  /// A snapshot of the iOS native PiP backend's private wiring, or
  /// `nil` when this controller doesn't drive the native backend (the
  /// direct sample-buffer path).
  ///
  /// This is intentionally SPI, not stable public API. It exists for
  /// the in-repo Showcase device-validation harness and may change or
  /// disappear per libVLC pin, outside SwiftVLC's public
  /// semantic-versioning contract.
  @_spi(ValidationHarness)
  public var nativeValidationProbe: NativePiPProbe? {
    nativeBackend?.makeValidationProbe()
  }

  /// A qualification-only snapshot of the playback policy sent to AVKit.
  @_spi(Qualification)
  public var playbackQualificationSnapshot: PiPPlaybackQualificationSnapshot {
    PiPPlaybackQualificationSnapshot(
      requiresLinearPlayback: nativeBackend?.requiresLinearPlayback
        ?? pipController?.requiresLinearPlayback
        ?? true,
      durationMilliseconds: playbackStateObservation.durationMilliseconds,
      isSeekable: playbackStateObservation.isSeekable
    )
  }

  /// The exact atomic length/time/seekability query exported to libVLC's
  /// native PiP module, paired with its current media identity.
  @_spi(Qualification)
  public var nativePlaybackQualificationSnapshot: NativePiPPlaybackQualificationSnapshot? {
    guard let nativeBackend else { return nil }
    var duration: Int64 = 0
    var time: Int64 = 0
    var seekable = ObjCBool(false)
    var generation: UInt64 = 0
    guard
      nativeBackend.mediaController.qualificationPlaybackSnapshot(
        length: &duration,
        time: &time,
        seekable: &seekable,
        generation: &generation
      )
    else { return nil }
    return NativePiPPlaybackQualificationSnapshot(
      mediaGeneration: generation,
      durationMilliseconds: duration,
      currentTimeMilliseconds: time,
      isSeekable: seekable.boolValue
    )
  }

  /// Exercises the exact relative-skip path AVKit uses and waits for its
  /// terminal result. The device harness uses this instead of trying to tap a
  /// locale-dependent system PiP control by its accessibility label.
  @_spi(Qualification)
  public func performQualificationSkip(bySeconds seconds: Double) async -> Bool {
    let interval = CMTime(seconds: seconds, preferredTimescale: 1000)
    if let nativeBackend {
      guard let offset = Self.skipOffsetMilliseconds(interval) else { return false }
      return await nativeBackend.mediaController.qualificationSeek(by: offset) == .settled
    }
    let request = Self.performSkip(
      on: player,
      by: interval
    )
    return await request.outcome == .settled
  }

  /// Exercises the backend-specific play/pause entry used by system PiP.
  /// Native drawable PiP enters through libVLC's media-controller bridge;
  /// direct sample-buffer PiP enters through AVKit's playback delegate.
  @_spi(Qualification)
  public func performQualificationSetPlaying(_ playing: Bool) -> Bool {
    if let nativeBackend {
      if playing {
        nativeBackend.mediaController.play()
      } else {
        nativeBackend.mediaController.pause()
      }
      return true
    } else {
      guard
        let avController = pipController,
        let delegate = avController.contentSource?.sampleBufferPlaybackDelegate,
        (delegate as AnyObject) === playbackDelegateProxy
      else { return false }
      delegate.pictureInPictureController(avController, setPlaying: playing)
      return true
    }
  }

  /// Issues a real direct-backend AVKit start request, then delivers a
  /// deterministic asynchronous failure through the installed delegate path.
  /// The request must first reach AVKit and return `.accepted`; the injected
  /// callback changes no attribution state directly and is filtered by the
  /// same current-controller identity check as a system callback.
  @_spi(Qualification)
  public func performAcceptedStartDelayedFailureQualification() -> PiPStartResult {
    guard nativeBackend == nil else { return .backendUnavailable }
    let result = start()
    guard
      result == .accepted,
      let avController = pipController,
      let delegate = avController.delegate,
      (delegate as AnyObject) === self
    else { return result }
    delegate.pictureInPictureController?(
      avController,
      failedToStartPictureInPictureWithError: NSError(
        domain: "SwiftVLC.Qualification.DelayedPiPStartFailure",
        code: 1
      )
    )
    return result
  }

  /// Issues a real native-backend start request, then routes a deterministic
  /// asynchronous failure through the installed libVLC/AVKit delegate bridge.
  /// This is candidate-only integration proof that native failed-start events
  /// are surfaced with their accepted request attribution intact.
  @_spi(Qualification)
  public func performNativeAcceptedStartFailureQualification() -> PiPStartResult {
    guard let nativeBackend else { return .backendUnavailable }
    let result = start()
    guard result == .accepted else { return result }
    guard nativeBackend.performAcceptedStartFailureQualification() else {
      return .backendUnavailable
    }
    return result
  }

  /// Exercises the same controller command entry point used by AVKit's
  /// sample-buffer playback delegate.
  @_spi(Qualification)
  public func performDeferredPauseQualificationCommand(playing: Bool) {
    handleSetPlaying(playing)
  }

  /// Whether the bounded controller task is still scheduled.
  @_spi(Qualification)
  public var isDeferredPauseQualificationInFlight: Bool {
    if case .scheduled = deferredPause {
      true
    } else {
      false
    }
  }

  /// Truth reported to AVKit's playback controls after a deferred command.
  @_spi(Qualification)
  public var deferredPauseQualificationControlsArePlaying: Bool {
    pipPlaybackActive && player.isPlaybackRequestedActive
  }
}

extension Player {
  /// The current media identity used by the in-repo replacement qualification
  /// lane to reject measurements and callbacks from an outgoing item.
  @_spi(Qualification)
  public var playbackQualificationGeneration: PlaybackGeneration {
    generation
  }

  /// Enables deterministic suppression of the two raw callbacks whose
  /// absence the capability-convergence lane must tolerate.
  @_spi(Qualification)
  public func suppressRawCapabilityEventsForQualification(_ suppressed: Bool) {
    isSuppressingRawCapabilityEvents = suppressed
    if suppressed {
      suppressedRawLengthEventCount = 0
      suppressedRawSeekableEventCount = 0
    }
  }

  /// Configures candidate-bound pause-capability fault injection. This alters
  /// only the capability decision; generation binding, retained commands,
  /// native command issuance, and outcome reconciliation remain live.
  @_spi(Qualification)
  public func configureDeferredPauseQualificationFault(
    _ fault: DeferredPauseQualificationFault
  ) {
    switch fault {
    case .disabled:
      configureQualificationPauseFault(mode: .disabled)
    case .permanentRejection:
      configureQualificationPauseFault(mode: .permanentRejection)
    case .transientRejection(let attempts):
      configureQualificationPauseFault(
        mode: .transientRejection,
        transientRejections: attempts
      )
    }
  }

  @_spi(Qualification)
  public var rawCapabilityEventSuppressionSnapshot: RawCapabilityEventSuppressionSnapshot {
    RawCapabilityEventSuppressionSnapshot(
      isEnabled: isSuppressingRawCapabilityEvents,
      suppressedLengthEventCount: suppressedRawLengthEventCount,
      suppressedSeekableEventCount: suppressedRawSeekableEventCount
    )
  }

  @_spi(Qualification)
  public var deferredPauseQualificationSnapshot: DeferredPauseQualificationSnapshot {
    let snapshot = qualificationPauseFaultSnapshot
    return DeferredPauseQualificationSnapshot(
      isEnabled: snapshot.isEnabled,
      forcedRejectionCount: snapshot.forcedRejectionCount,
      nativePauseCommandCount: snapshot.nativePauseCommandCount,
      remainingTransientRejections: snapshot.remainingTransientRejections
    )
  }
}

#endif
