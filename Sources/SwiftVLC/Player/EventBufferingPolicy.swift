/// Buffering behavior for one event-stream subscription.
///
/// Every subscription owns an independent buffer between libVLC's event
/// thread (the producer) and the consuming task. The policy decides what
/// happens when the consumer lags behind the producer.
public enum EventBufferingPolicy: Sendable, Equatable {
  /// Keep the newest `count` undelivered events and drop the oldest once
  /// the buffer is full. Counts below 1 are treated as 1.
  ///
  /// Bounded memory, lossy under backlog: a consumer stalled across a
  /// burst of high-frequency events (`timeChanged` fires ~30 Hz during
  /// playback) can lose one-shot transitions that happened to be buffered
  /// behind the firehose.
  case newest(Int)

  /// Never drop an event.
  ///
  /// Undelivered events accumulate without bound, so memory grows with
  /// consumer lag. Use for consumers that must not miss one-shot terminal
  /// transitions; pair with a ``Player/events(policy:filter:)`` filter to
  /// keep the firehose out of the buffer entirely.
  case unbounded
}
