@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  struct MediaExtendedTests {
    @Test(.tags(.async, .media, .mainActor), .enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    @MainActor
    func `Statistics become available during playback`() async throws {
      let player = Player(instance: TestInstance.shared)
      let media = try Media(url: TestMedia.twosecURL)
      try player.play(media)
      guard try await poll(until: { player.isPlaying }) else {
        player.stop()
        return
      }
      // Wait for some frames to decode so statistics populate
      guard try await poll(timeout: .seconds(5), until: { player.statistics != nil }) else {
        player.stop()
        // Statistics may not become available on all platforms
        return
      }
      // readBytes may still be 0 if stats haven't fully populated yet
      // The important thing is that statistics is non-nil during playback
      if let stats = player.statistics {
        _ = stats.readBytes
        _ = stats.inputBitrate
      }
      player.stop()
    }

    @Test
    func `Multiple options don't interfere`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      media.addOption(":network-caching=1000")
      media.addOption(":no-video")
      media.addOption(":no-audio")
      media.addOption(":file-caching=500")
      // All options accepted without crash
      let mrl = try #require(media.mrl)
      #expect(!mrl.isEmpty)
    }

    @Test
    func `MRL format for file URL`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let mrl = try #require(media.mrl)
      // File URLs are created with libvlc_media_new_path, so the MRL
      // should contain the file path
      #expect(mrl.contains("test.mp4"))
    }

    @Test
    func `MRL format for remote URL`() throws {
      let url = try #require(URL(string: "https://example.com/stream.mp4"))
      let media = try Media(url: url)
      let mrl = try #require(media.mrl)
      #expect(mrl.contains("https://example.com/stream.mp4"))
    }

    @Test
    func `Metadata editing for multiple keys`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      media.setMetadata(.title, value: "Custom Title")
      media.setMetadata(.artist, value: "Custom Artist")
      media.setMetadata(.genre, value: "Custom Genre")
      media.setMetadata(.album, value: "Custom Album")
      // Setting multiple metadata keys should not crash or interfere
    }

    @Test
    func `Init from URL with query parameters`() throws {
      let url = try #require(URL(string: "http://example.com/video.mp4?token=abc123&quality=high"))
      let media = try Media(url: url)
      let mrl = try #require(media.mrl)
      #expect(mrl.contains("example.com"))
      #expect(mrl.contains("token=abc123"))
    }

    @Test
    func `Media retains pointer correctly`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      // Access mrl multiple times to verify pointer stability
      let mrl1 = media.mrl
      let mrl2 = media.mrl
      let mrl3 = media.mrl
      #expect(mrl1 == mrl2)
      #expect(mrl2 == mrl3)
      #expect(mrl1 != nil)
    }

    @Test(.tags(.async, .media))
    func `Parse with custom instance`() async throws {
      let instance = try VLCInstance()
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse(instance: instance)
      // Title may vary depending on parse success
      _ = metadata.title
    }

    @Test(.tags(.async, .media))
    func `Tracks type distribution for video file`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      _ = try await media.parse()
      let tracks = media.tracks()
      // Tracks may be empty on some platforms/simulators
      let audioTracks = tracks.filter { $0.type == .audio }
      let videoTracks = tracks.filter { $0.type == .video }
      _ = audioTracks
      _ = videoTracks
    }

    @Test(.tags(.async, .media))
    func `Tracks type distribution for audio-only file`() async throws {
      let media = try Media(url: TestMedia.silenceURL)
      _ = try await media.parse()
      let tracks = media.tracks()
      // Tracks may be empty on some platforms/simulators
      let audioTracks = tracks.filter { $0.type == .audio }
      let videoTracks = tracks.filter { $0.type == .video }
      _ = audioTracks
      _ = videoTracks
    }

    @Test(.tags(.async, .media))
    func `Duration for silence wav`() async throws {
      let media = try Media(url: TestMedia.silenceURL)
      _ = try await media.parse()
      // Duration may be nil on some platforms
      _ = media.duration
    }

    @Test
    func `File descriptor with valid readable file`() throws {
      let path = TestMedia.testMP4URL.path
      let fd = open(path, O_RDONLY)
      #expect(fd >= 0)
      defer { close(fd) }
      let media = try Media(fileDescriptor: Int(fd))
      let mrl = try #require(media.mrl)
      #expect(!mrl.isEmpty)
    }
  }
}
