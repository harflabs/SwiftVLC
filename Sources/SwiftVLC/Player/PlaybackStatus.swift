/// Opaque identity of one media session on a ``Player``.
///
/// A session begins when the player adopts a media and ends when it adopts a
/// different one. It advances for every media change, whether the wrapper asked
/// for it (``Player/load(_:)``, replacement through ``Player/play(_:)``,
/// ``Player/recast(to:)``) or libVLC reported one from elsewhere — a
/// ``MediaListPlayer`` advancing the list calls straight into libVLC and never
/// touches SwiftVLC's own transport methods.
///
/// The value carries no meaning beyond identity and order. Compare it; do not
/// interpret it. Two values being equal means they describe the same session,
/// which is the question worth asking when a late-arriving event might belong
/// to media that is no longer loaded.
public struct PlaybackGeneration: Hashable, Sendable, Comparable, CustomStringConvertible {
  let value: UInt64

  init(_ value: UInt64) {
    self.value = value
  }

  /// Orders two generations by when their sessions began.
  ///
  /// Ordering is only meaningful between generations from the same player
  /// observed within one run. SwiftVLC traps rather than aliasing an earlier
  /// identity if the 64-bit counter is ever exhausted.
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.value < rhs.value
  }

  /// A short description for logging and test failure messages.
  public var description: String {
    "generation \(value)"
  }
}

/// A ``PlayerState`` together with the media session it describes.
///
/// ``PlayerState`` alone cannot answer "is this still about the media I think
/// is loaded". A `.playing` that arrives after a playlist advance looks
/// identical to one from the media before it, and a consumer restoring state
/// across a media change has no way to tell that its work has been superseded.
/// Pairing the state with a ``PlaybackGeneration`` makes that decidable.
public struct PlaybackStatus: Hashable, Sendable {
  /// The player state at the moment this status was published.
  public let state: PlayerState
  /// The media session ``state`` belongs to.
  public let generation: PlaybackGeneration
}
