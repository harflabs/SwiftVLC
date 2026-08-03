import Synchronization

/// Supplies one vout identity sequence across same-controller native-handle
/// replacements. It is deliberately independent of renderer ownership so a
/// retired handle can finish callbacks without keeping the old renderer alive.
final class PixelBufferVoutGenerationCounter: Sendable {
  private let value = Mutex<UInt64>(0)

  func next() -> UInt64 {
    value.withLock {
      $0 &+= 1
      return $0
    }
  }
}
