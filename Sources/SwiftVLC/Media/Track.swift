import CLibVLC

/// A media track (audio, video, or subtitle).
///
/// Each track has a stable string ``id`` and type-specific properties
/// (e.g. ``channels`` for audio, ``width``/``height`` for video).
///
/// ```swift
/// for track in player.audioTracks {
///     print("\(track.name) — \(track.language ?? "unknown")")
/// }
/// ```
public struct Track: Sendable, Identifiable, Hashable {
  /// Stable string identifier from libVLC.
  public let id: String

  /// Track type: audio, video, or subtitle.
  public let type: TrackType

  /// Human-readable track name.
  public let name: String

  /// Codec identifier as a FourCC integer (e.g. `0x34363248` for "H264").
  public let codec: Int

  /// ISO 639 language code.
  public let language: String?

  /// Track description from the container.
  public let trackDescription: String?

  /// Whether this track is currently selected.
  public let isSelected: Bool

  /// Bitrate in bits/second (0 if unknown).
  public let bitrate: Int

  // MARK: - Audio

  /// Number of audio channels (`nil` for non-audio tracks).
  public let channels: Int?

  /// Audio sample rate in Hz (`nil` for non-audio tracks).
  public let sampleRate: Int?

  // MARK: - Video

  /// Video width in pixels (`nil` for non-video tracks).
  public let width: Int?

  /// Video height in pixels (`nil` for non-video tracks).
  public let height: Int?

  /// Video frame rate in frames per second (`nil` for non-video tracks).
  public let frameRate: Double?

  // MARK: - Subtitle

  /// Subtitle text encoding (`nil` for non-subtitle tracks).
  public let encoding: String?

  public static func == (lhs: Track, rhs: Track) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

/// Track type classification.
public enum TrackType: Sendable, Hashable, CustomStringConvertible {
  /// An audio track.
  case audio
  /// A video track.
  case video
  /// A subtitle or closed-caption track.
  case subtitle
  /// A track type not recognized by SwiftVLC.
  case unknown

  public var description: String {
    switch self {
    case .audio: "audio"
    case .video: "video"
    case .subtitle: "subtitle"
    case .unknown: "unknown"
    }
  }
}

// MARK: - Internal Construction

extension Track {
  init(from cTrack: UnsafePointer<libvlc_media_track_t>) {
    let t = cTrack.pointee

    id = t.psz_id.map { String(cString: $0) } ?? "\(t.i_id)"
    type = TrackType(from: t.i_type)
    name = t.psz_name.map { String(cString: $0) }
      ?? t.psz_description.map { String(cString: $0) }
      ?? "Track \(t.i_id)"
    codec = Int(t.i_codec)
    language = t.psz_language.map { String(cString: $0) }
    trackDescription = t.psz_description.map { String(cString: $0) }
    isSelected = t.selected
    bitrate = Int(t.i_bitrate)

    switch t.i_type {
    case libvlc_track_audio where t.audio != nil:
      let audio = t.audio.pointee
      channels = Int(audio.i_channels)
      sampleRate = Int(audio.i_rate)
      width = nil
      height = nil
      frameRate = nil
      encoding = nil
    case libvlc_track_video where t.video != nil:
      let video = t.video.pointee
      width = Int(video.i_width)
      height = Int(video.i_height)
      if video.i_frame_rate_den > 0 {
        frameRate = Double(video.i_frame_rate_num) / Double(video.i_frame_rate_den)
      } else {
        frameRate = nil
      }
      channels = nil
      sampleRate = nil
      encoding = nil
    case libvlc_track_text where t.subtitle != nil:
      encoding = t.subtitle.pointee.psz_encoding.map { String(cString: $0) }
      channels = nil
      sampleRate = nil
      width = nil
      height = nil
      frameRate = nil
    default:
      channels = nil
      sampleRate = nil
      width = nil
      height = nil
      frameRate = nil
      encoding = nil
    }
  }
}

/// Type of external track that can be added to a player during playback.
public enum MediaSlaveType: Sendable, Hashable, CustomStringConvertible {
  /// An external subtitle file (e.g. `.srt`, `.ass`).
  case subtitle
  /// An external audio track file.
  case audio

  public var description: String {
    switch self {
    case .subtitle: "subtitle"
    case .audio: "audio"
    }
  }

  var cValue: libvlc_media_slave_type_t {
    switch self {
    case .subtitle: libvlc_media_slave_type_subtitle
    case .audio: libvlc_media_slave_type_audio
    }
  }
}

extension TrackType {
  init(from cType: libvlc_track_type_t) {
    switch cType {
    case libvlc_track_audio: self = .audio
    case libvlc_track_video: self = .video
    case libvlc_track_text: self = .subtitle
    default: self = .unknown
    }
  }

  var cValue: libvlc_track_type_t {
    switch self {
    case .audio: libvlc_track_audio
    case .video: libvlc_track_video
    case .subtitle: libvlc_track_text
    case .unknown: libvlc_track_unknown
    }
  }
}
