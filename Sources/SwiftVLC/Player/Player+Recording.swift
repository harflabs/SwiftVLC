import CLibVLC

/// Snapshot capture and stream recording.
extension Player {
  /// Takes a snapshot of the current video frame and writes it to disk as PNG.
  ///
  /// Pass `0` for `width` or `height` to derive that dimension from the
  /// other while preserving the source aspect ratio. Passing `0` for both
  /// writes the frame at its native resolution.
  ///
  /// - Parameters:
  ///   - path: Destination file path. The file is always PNG regardless of
  ///     the extension you provide.
  ///   - width: Desired width in pixels, or `0` to derive from `height`
  ///     and the aspect ratio.
  ///   - height: Desired height in pixels, or `0` to derive from `width`
  ///     and the aspect ratio.
  /// - Throws: ``VLCError/operationFailed(_:)`` if no frame is available
  ///   (e.g. audio-only media) or the file cannot be written.
  public func takeSnapshot(to path: String, width: Int = 0, height: Int = 0) throws(VLCError) {
    guard libvlc_video_take_snapshot(pointer, 0, path, UInt32(width), UInt32(height)) == 0 else {
      throw .operationFailed("Take snapshot")
    }
  }

  /// Starts recording the current stream to the specified directory.
  /// No-op when no media is loaded.
  ///
  /// Listen to ``PlayerEvent/recordingChanged(isRecording:filePath:)`` for state updates.
  /// - Parameter directory: Path to save recording (`nil` for default).
  public func startRecording(to directory: String? = nil) {
    guard currentMedia != nil else { return }
    libvlc_media_player_record(pointer, true, directory)
  }

  /// Stops recording the current stream. No-op when no media is loaded.
  public func stopRecording() {
    guard currentMedia != nil else { return }
    libvlc_media_player_record(pointer, false, nil)
  }
}
