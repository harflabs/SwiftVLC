import CLibVLC

/// A-B loop control: set, query, reset.
extension Player {
  /// Sets an A-B loop using absolute times.
  /// - Throws: ``VLCError/invalidInput(_:)`` for negative, overflowing, or
  ///   non-increasing boundaries, and ``VLCError/operationFailed(_:)`` if
  ///   libVLC rejects the loop.
  public func setABLoop(a: Duration, b: Duration) throws(VLCError) {
    let aMilliseconds = try a.checkedNonnegativeMilliseconds(parameter: "a")
    let bMilliseconds = try b.checkedNonnegativeMilliseconds(parameter: "b")
    guard aMilliseconds < bMilliseconds else {
      throw .invalidInput("A-B loop requires a < b")
    }
    guard libvlc_media_player_set_abloop_time(pointer, aMilliseconds, bMilliseconds) == 0 else {
      throw .operationFailed("Set A-B loop by time")
    }
    withMutation(keyPath: \.abLoopState) {}
  }

  /// Sets an A-B loop using fractional positions (0.0...1.0).
  /// - Throws: ``VLCError/invalidInput(_:)`` for non-increasing
  ///   boundaries, and ``VLCError/operationFailed(_:)`` if libVLC rejects
  ///   the loop.
  public func setABLoop(aPosition: PlaybackPosition, bPosition: PlaybackPosition) throws(VLCError) {
    guard aPosition < bPosition else {
      throw .invalidInput("A-B loop requires aPosition < bPosition")
    }
    guard libvlc_media_player_set_abloop_position(pointer, aPosition.rawValue, bPosition.rawValue) == 0 else {
      throw .operationFailed("Set A-B loop by position")
    }
    withMutation(keyPath: \.abLoopState) {}
  }

  /// Resets (disables) the A-B loop.
  /// - Throws: `VLCError.operationFailed` if the loop cannot be reset.
  public func resetABLoop() throws(VLCError) {
    guard libvlc_media_player_reset_abloop(pointer) == 0 else {
      throw .operationFailed("Reset A-B loop")
    }
    withMutation(keyPath: \.abLoopState) {}
  }

  /// Current A-B loop state.
  public var abLoopState: ABLoopState {
    access(keyPath: \.abLoopState)
    var aTime: Int64 = 0
    var aPos: Double = 0
    var bTime: Int64 = 0
    var bPos: Double = 0
    let state = libvlc_media_player_get_abloop(pointer, &aTime, &aPos, &bTime, &bPos)
    return ABLoopState(from: state)
  }
}
