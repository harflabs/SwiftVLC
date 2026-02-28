import CLibVLC

/// Playback statistics for a media item.
public struct MediaStatistics: Sendable {
    // Input
    public let readBytes: UInt64
    public let inputBitrate: Float

    // Demux
    public let demuxReadBytes: UInt64
    public let demuxBitrate: Float
    public let demuxCorrupted: UInt64
    public let demuxDiscontinuity: UInt64

    // Decoders
    public let decodedVideo: UInt64
    public let decodedAudio: UInt64

    // Video Output
    public let displayedPictures: UInt64
    public let latePictures: UInt64
    public let lostPictures: UInt64

    // Audio Output
    public let playedAudioBuffers: UInt64
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

public extension Media {
    /// Returns current playback statistics, or `nil` if unavailable.
    func statistics() -> MediaStatistics? {
        var stats = libvlc_media_stats_t()
        guard libvlc_media_get_stats(pointer, &stats) else { return nil }
        return MediaStatistics(from: stats)
    }
}
