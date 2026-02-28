import CLibVLC
import Foundation

/// Immutable metadata parsed from a ``Media`` source.
///
/// All metadata keys from libVLC are exposed as typed properties.
/// Access any key programmatically via subscript:
/// ```swift
/// let title = metadata[.title]
/// ```
public struct Metadata: Sendable, Equatable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let albumArtist: String?
    public let genre: String?
    public let duration: Duration?
    public let artworkURL: URL?
    public let date: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let description: String?
    public let showName: String?
    public let season: Int?
    public let episode: Int?
    public let copyright: String?
    public let publisher: String?
    public let language: String?

    /// Access any metadata key.
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

/// All libVLC metadata keys.
public enum MetadataKey: Int, Sendable, CaseIterable, Hashable {
    case title = 0
    case artist = 1
    case genre = 2
    case copyright = 3
    case album = 4
    case trackNumber = 5
    case description = 6
    case rating = 7
    case date = 8
    case setting = 9
    case url = 10
    case language = 11
    case nowPlaying = 12
    case publisher = 13
    case encodedBy = 14
    case artworkURL = 15
    case trackID = 16
    case trackTotal = 17
    case director = 18
    case season = 19
    case episode = 20
    case showName = 21
    case actors = 22
    case albumArtist = 23
    case discNumber = 24
    case discTotal = 25

    var cValue: libvlc_meta_t {
        libvlc_meta_t(rawValue: UInt32(rawValue))
    }
}
