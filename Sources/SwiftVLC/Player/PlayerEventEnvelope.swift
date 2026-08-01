/// Opaque identity of the native libVLC player that emitted an event.
///
/// A ``Player`` can replace its underlying libVLC player while the Swift
/// object and its event streams stay alive. Native pointer addresses are not
/// identities: an allocator may reuse a retired address for a later handle.
/// This monotonic value makes an event from the retired handle rejectable even
/// in that case.
///
/// This is deliberately distinct from ``PlaybackGeneration``. A playback
/// generation identifies a media session, while a native-player generation
/// identifies the concrete libVLC handle carrying it. One can change without
/// the other.
public struct NativePlayerGeneration: Hashable, Sendable, Comparable, CustomStringConvertible {
  let value: UInt64

  init(_ value: UInt64) {
    self.value = value
  }

  /// Orders two generations by when their native handles were installed.
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.value < rhs.value
  }

  /// A short description suitable for diagnostics.
  public var description: String {
    "native generation \(value)"
  }
}

/// A raw player event paired with the native handle that emitted it.
///
/// The legacy ``Player/events`` stream remains available for source
/// compatibility. Consumers that retain, queue, or merge events across native
/// handle replacement should use this envelope and compare
/// ``nativeGeneration`` with ``Player/nativeEventGeneration`` before applying
/// the event.
public struct PlayerEventEnvelope: Sendable {
  /// The raw event mapped from libVLC.
  public let event: PlayerEvent
  /// The native libVLC handle that emitted ``event``.
  public let nativeGeneration: NativePlayerGeneration
}

extension Player {
  /// The native libVLC handle currently installed behind this player.
  ///
  /// Compare this value with ``PlayerEventEnvelope/nativeGeneration`` before
  /// applying an event that may have waited in a queue across renderer recast
  /// or native-handle replacement.
  public nonisolated var nativeEventGeneration: NativePlayerGeneration {
    eventBridge.currentNativePlayerGeneration
  }

  /// Raw events paired with the native handle that emitted them.
  ///
  /// The default newest-64 policy has the same bounded, lossy behavior as
  /// ``Player/events``. Use ``eventEnvelopes(policy:filter:)`` or the
  /// lane-specific envelope streams when one-shot control delivery must be
  /// lossless.
  public nonisolated var eventEnvelopes: AsyncStream<PlayerEventEnvelope> {
    eventBridge.makeEnvelopeStream(policy: .newest(64), filter: nil)
  }

  /// Raw event envelopes with an explicit buffering policy and filter.
  ///
  /// The filter runs synchronously on libVLC's event thread under the same
  /// constraints documented by ``Player/events(policy:filter:)``.
  public nonisolated func eventEnvelopes(
    policy: EventBufferingPolicy = .newest(64),
    filter: (@Sendable (PlayerEventEnvelope) -> Bool)? = nil
  ) -> AsyncStream<PlayerEventEnvelope> {
    eventBridge.makeEnvelopeStream(policy: policy, filter: filter)
  }
}
