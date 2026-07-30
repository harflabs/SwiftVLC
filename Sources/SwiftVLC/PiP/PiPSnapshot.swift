#if os(iOS) || os(macOS)
/// The Picture in Picture state a subscriber needs in order to act, delivered
/// as a value rather than inferred from a sequence of events.
///
/// ``PiPController/pipEvents`` reports transitions and nothing else, so a
/// subscriber that attaches after PiP has already started sees nothing until it
/// stops. Auto-start makes that ordinary rather than exotic: the system can
/// begin PiP before any application code has had a chance to subscribe.
///
/// Reading ``PiPController/isActive`` alongside the event stream does not fix
/// it. The property and the stream are separate publications, so a subscriber
/// can observe a state that never coexisted with the event it arrived beside.
/// A snapshot is one value, so the fields in it were true together.
public struct PiPSnapshot: Hashable, Sendable {
  /// Whether Picture in Picture is currently running.
  public let isActive: Bool
  /// Whether the current backend and media can support Picture in Picture.
  public let isPossible: Bool
  /// The media session these flags describe.
  ///
  /// A snapshot outlives the media it was taken for. Comparing this against
  /// ``Player/generation`` tells a consumer whether the snapshot still
  /// describes the media that is loaded now, which matters because a media
  /// change tears Picture in Picture down.
  public let mediaGeneration: PlaybackGeneration
  /// A monotonically increasing counter for this controller.
  ///
  /// Two subscribers holding the same revision hold the same snapshot, without
  /// either having to wait for another transition to find out. Ordering is only
  /// meaningful within one controller.
  public let revision: UInt64
}
#endif
