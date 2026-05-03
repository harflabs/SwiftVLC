import CLibVLC

/// A-B loop control: set, query, reset.
extension Player {
  /// Sets an A-B loop using absolute times.
  /// - Throws: `VLCError.operationFailed` if the loop cannot be set.
  public func setABLoop(a: Duration, b: Duration) throws(VLCError) {
    guard libvlc_media_player_set_abloop_time(pointer, a.milliseconds, b.milliseconds) == 0 else {
      throw .operationFailed("Set A-B loop by time")
    }
    withMutation(keyPath: \.abLoopState) {}
  }

  /// Sets an A-B loop using fractional positions (0.0...1.0).
  /// - Throws: `VLCError.operationFailed` if the loop cannot be set.
  public func setABLoop(aPosition: Double, bPosition: Double) throws(VLCError) {
    guard libvlc_media_player_set_abloop_position(pointer, aPosition, bPosition) == 0 else {
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
