import CLibVLC

/// Playback statistics for a media item.
///
/// Provides real-time metrics about input, demux, decoding, and output.
/// Access via ``Player/statistics`` during playback.
public struct MediaStatistics: Sendable, Equatable {
  // MARK: - Input

  /// Total bytes read from the input source.
  public let readBytes: UInt64
  /// Input bitrate in kilobits per second.
  public let inputBitrate: Float

  // MARK: - Demux

  /// Total bytes processed by the demuxer.
  public let demuxReadBytes: UInt64
  /// Demuxer bitrate in kilobits per second.
  public let demuxBitrate: Float
  /// Number of corrupted packets detected.
  public let demuxCorrupted: UInt64
  /// Number of discontinuities (timestamp jumps) detected.
  public let demuxDiscontinuity: UInt64

  // MARK: - Decoders

  /// Number of video frames decoded.
  public let decodedVideo: UInt64
  /// Number of audio frames decoded.
  public let decodedAudio: UInt64

  // MARK: - Video Output

  /// Number of video frames displayed.
  public let displayedPictures: UInt64
  /// Number of video frames displayed late (potential stutter).
  public let latePictures: UInt64
  /// Number of video frames dropped (decoder too slow).
  public let lostPictures: UInt64

  // MARK: - Audio Output

  /// Number of audio buffers played.
  public let playedAudioBuffers: UInt64
  /// Number of audio buffers dropped (decoder too slow).
  public let lostAudioBuffers: UInt64

  init(from stats: libvlc_media_stats_t) {
    readBytes = stats.i_read_bytes
    inputBitrate = stats.f_input_bitrate
    demuxReadBytes = stats.i_demux_read_bytes
    demuxBitrate = stats.f_demux_bitrate
    demuxCorrupted = stats.i_demux_corrupted
    demuxDiscontinuity = stats.i_demux_discontinuity
    decodedVideo = stats.i_decoded_video
    decodedAudio = stats.i_decoded_audio
    displayedPictures = stats.i_displayed_pictures
    latePictures = stats.i_late_pictures
    lostPictures = stats.i_lost_pictures
    playedAudioBuffers = stats.i_played_abuffers
    lostAudioBuffers = stats.i_lost_abuffers
  }
}

extension Media {
  /// Returns current playback statistics, or `nil` if unavailable.
  public func statistics() -> MediaStatistics? {
    var stats = libvlc_media_stats_t()
    guard libvlc_media_get_stats(pointer, &stats) else { return nil }
    return MediaStatistics(from: stats)
  }
}
