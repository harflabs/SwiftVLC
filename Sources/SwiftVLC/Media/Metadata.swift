import CLibVLC
import Foundation

/// Immutable metadata parsed from a ``Media`` source.
///
/// All metadata keys from libVLC are exposed as typed properties.
/// Access any key programmatically via subscript:
/// ```swift
/// let title = metadata[.title]
/// ```
public struct Metadata: Sendable, Hashable {
  /// Track or media title.
  public let title: String?
  /// Performing artist.
  public let artist: String?
  /// Album name.
  public let album: String?
  /// Album-level artist (may differ from track artist on compilations).
  public let albumArtist: String?
  /// Genre (e.g. "Rock", "Classical").
  public let genre: String?
  /// Media duration, derived from the container (may differ from decoded duration).
  public let duration: Duration?
  /// URL to album art or thumbnail image.
  public let artworkURL: URL?
  /// Release date as a free-form string (typically "YYYY" or "YYYY-MM-DD").
  public let date: String?
  /// Track number within the album.
  public let trackNumber: Int?
  /// Disc number in a multi-disc set.
  public let discNumber: Int?
  /// Free-form description or comment embedded in the file.
  public let description: String?
  /// TV show name (for episodic content).
  public let showName: String?
  /// Season number (for episodic content).
  public let season: Int?
  /// Episode number (for episodic content).
  public let episode: Int?
  /// Copyright notice.
  public let copyright: String?
  /// Publisher or record label.
  public let publisher: String?
  /// Content language (ISO 639 code or free-form).
  public let language: String?

  /// Access any metadata key.
  /// - Parameter key: The metadata key to fetch.
  /// - Returns: The value libVLC reported for `key`, or `nil` if the
  ///   media omitted it.
  public subscript(key: MetadataKey) -> String? {
    values[key]
  }

  private let values: [MetadataKey: String]

  init(from media: OpaquePointer) {
    var vals: [MetadataKey: String] = [:]
    for key in MetadataKey.allCases {
      if let cstr = libvlc_media_get_meta(media, key.cValue) {
        vals[key] = String(cString: cstr)
        libvlc_free(cstr)
      }
    }
    values = vals

    title = vals[.title]
    artist = vals[.artist]
    album = vals[.album]
    albumArtist = vals[.albumArtist]
    genre = vals[.genre]
    date = vals[.date]
    description = vals[.description]
    showName = vals[.showName]
    copyright = vals[.copyright]
    publisher = vals[.publisher]
    language = vals[.language]

    trackNumber = vals[.trackNumber].flatMap(Int.init)
    discNumber = vals[.discNumber].flatMap(Int.init)
    season = vals[.season].flatMap(Int.init)
    episode = vals[.episode].flatMap(Int.init)

    artworkURL = vals[.artworkURL].flatMap(URL.init(string:))

    let ms = libvlc_media_get_duration(media)
    duration = ms >= 0 ? .milliseconds(ms) : nil
  }
}

/// Keys for accessing individual metadata fields on a ``Media`` item.
///
/// Raw values match libVLC's `libvlc_meta_t` enumeration.
public enum MetadataKey: Int, Sendable, CaseIterable, Hashable {
  /// Track or media title.
  case title = 0
  /// Performing artist.
  case artist = 1
  /// Genre (e.g. "Rock", "Classical").
  case genre = 2
  /// Copyright notice.
  case copyright = 3
  /// Album name.
  case album = 4
  /// Track number within the album, as a string.
  case trackNumber = 5
  /// Free-form description or comment embedded in the file.
  case description = 6
  /// User or critic rating.
  case rating = 7
  /// Release date (typically "YYYY" or "YYYY-MM-DD").
  case date = 8
  /// Application-specific setting string.
  case setting = 9
  /// URL associated with the media (e.g. podcast link).
  case url = 10
  /// Content language (ISO 639 code or free-form).
  case language = 11
  /// Currently playing content (often used by radio streams).
  case nowPlaying = 12
  /// Publisher or record label.
  case publisher = 13
  /// Software or person that encoded the file.
  case encodedBy = 14
  /// URL to album art or thumbnail image.
  case artworkURL = 15
  /// Unique track identifier within a collection.
  case trackID = 16
  /// Total number of tracks in the album or collection.
  case trackTotal = 17
  /// Director (for film and episodic content).
  case director = 18
  /// Season number (for episodic content).
  case season = 19
  /// Episode number (for episodic content).
  case episode = 20
  /// TV show name (for episodic content).
  case showName = 21
  /// Cast members, typically as a delimited list.
  case actors = 22
  /// Album-level artist (may differ from track artist on compilations).
  case albumArtist = 23
  /// Disc number in a multi-disc set.
  case discNumber = 24
  /// Total number of discs in a multi-disc set.
  case discTotal = 25

  var cValue: libvlc_meta_t {
    libvlc_meta_t(rawValue: UInt32(rawValue))
  }
}
