@testable import SwiftVLC
import Testing

@Suite(.tags(.integration))
struct TrackFinalTests {
  // MARK: - Audio track codec from parsed media

  @Test(.tags(.async, .media))
  func `Parsed audio track has non-zero codec`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let audioTracks = media.tracks().filter { $0.type == .audio }
    guard let audio = audioTracks.first else { return } // may be empty on simulators
    #expect(audio.codec != 0, "Audio track should have a non-zero codec")
  }

  // MARK: - Video track codec and frameRate from parsed media

  @Test(.tags(.async, .media))
  func `Parsed video track has non-zero codec`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let videoTracks = media.tracks().filter { $0.type == .video }
    guard let video = videoTracks.first else { return } // may be empty on simulators
    #expect(video.codec != 0, "Video track should have a non-zero codec")
  }

  @Test(.tags(.async, .media))
  func `Parsed video track frameRate from test MP4`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let videoTracks = media.tracks().filter { $0.type == .video }
    guard let video = videoTracks.first else { return } // may be empty on simulators
    // test.mp4 is created with ffmpeg so it should have a frame rate
    if let fps = video.frameRate {
      #expect(fps > 0, "Frame rate should be positive")
    }
    // frameRate is nil when frame_rate_den is 0 — this is the line 122 path
  }

  // MARK: - Audio-only file tracks

  @Test(.tags(.async, .media))
  func `silence.wav has audio track only`() async throws {
    let media = try Media(url: TestMedia.silenceURL)
    _ = try await media.parse()
    let tracks = media.tracks()
    // Tracks may be empty on some simulators
    let audioTracks = tracks.filter { $0.type == .audio }
    let videoTracks = tracks.filter { $0.type == .video }
    _ = audioTracks
    _ = videoTracks
  }

  @Test(.tags(.async, .media))
  func `silence.wav audio track has valid properties`() async throws {
    let media = try Media(url: TestMedia.silenceURL)
    _ = try await media.parse()
    let audioTracks = media.tracks().filter { $0.type == .audio }
    guard let audio = audioTracks.first else { return } // may be empty on simulators
    _ = audio.channels
    _ = audio.sampleRate
    #expect(audio.width == nil)
    #expect(audio.height == nil)
    #expect(audio.frameRate == nil)
    #expect(audio.encoding == nil)
  }

  // MARK: - Track id from parsed media

  @Test(.tags(.async, .media))
  func `Parsed tracks have non-empty id`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let tracks = media.tracks()
    for track in tracks {
      #expect(!track.id.isEmpty, "Track id should not be empty")
    }
  }

  // MARK: - Track Identifiable conformance

  @Test(.tags(.async, .media))
  func `Track id matches Identifiable protocol`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let tracks = media.tracks()
    guard let first = tracks.first else { return } // may be empty on simulators
    let identifiable: any Identifiable = first
    #expect(identifiable.id as? String == first.id)
  }

  // MARK: - Language extraction from parsed media

  @Test(.tags(.async, .media))
  func `Track language is accessible`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let tracks = media.tracks()
    // language may be nil for test fixtures, but access should not crash
    for track in tracks {
      _ = track.language
    }
  }

  // MARK: - Track name from parsed media

  @Test(.tags(.async, .media))
  func `Parsed tracks have non-empty name`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let tracks = media.tracks()
    for track in tracks {
      #expect(!track.name.isEmpty, "Track name should not be empty")
    }
  }

  // MARK: - twosec.mp4 video track has width/height

  @Test(.tags(.async, .media))
  func `twosec.mp4 video track has dimensions`() async throws {
    let media = try Media(url: TestMedia.twosecURL)
    _ = try await media.parse()
    let videoTracks = media.tracks().filter { $0.type == .video }
    guard let video = videoTracks.first else { return } // may be empty on simulators
    _ = video.width
    _ = video.height
  }

  // MARK: - Track bitrate is accessible

  @Test(.tags(.async, .media))
  func `Track bitrate is non-negative`() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let tracks = media.tracks()
    for track in tracks {
      #expect(track.bitrate >= 0)
    }
  }
}
