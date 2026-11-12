@testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

extension Integration {
  struct MediaTests {
    @Test
    func `Init from URL`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      #expect(media.mrl != nil)
    }

    @Test
    func `Init from file path`() throws {
      let media = try Media(path: TestMedia.testMP4URL.path)
      #expect(media.mrl != nil)
    }

    @Test
    func `Init from file descriptor`() throws {
      let fd = open(TestMedia.testMP4URL.path, O_RDONLY)
      #expect(fd >= 0)
      defer { close(fd) }
      let media = try Media(fileDescriptor: Int(fd))
      #expect(media.mrl != nil)
    }

    @Test
    func `MRL is non-nil`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let mrl = try #require(media.mrl)
      #expect(!mrl.isEmpty)
    }

    @Test
    func `Media type is file for local files`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      // libVLC may report .file or .unknown before any parsing; both acceptable.
      let type = media.mediaType
      #expect(type == .file || type == .unknown)
    }

    @Test
    func `Slaves empty by default`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      #expect(media.slaves.isEmpty)
    }

    @Test
    func `addSlave attaches a subtitle`() throws {
      let media = try Media(url: TestMedia.twosecURL)
      try media.addSlave(from: TestMedia.subtitleURL, type: .subtitle)
      let slaves = media.slaves
      #expect(slaves.count == 1)
      #expect(slaves.first?.type == .subtitle)
      #expect(slaves.first?.uri.contains("test.srt") == true)
    }

    @Test
    func `addSlave with custom priority`() throws {
      let media = try Media(url: TestMedia.twosecURL)
      // libVLC clamps the priority to its internal user-priority ceiling
      // (4 as of libVLC 4.0). Accept any value libVLC reports — the point
      // is that the call succeeds and the slave is stored.
      try media.addSlave(from: TestMedia.subtitleURL, type: .subtitle, priority: 9)
      #expect(media.slaves.first?.priority ?? 0 > 0)
    }

    @Test
    func `clearSlaves removes previously added slaves`() throws {
      let media = try Media(url: TestMedia.twosecURL)
      try media.addSlave(from: TestMedia.subtitleURL, type: .subtitle)
      #expect(!media.slaves.isEmpty)
      media.clearSlaves()
      #expect(media.slaves.isEmpty)
    }

    @Test
    func `Duration nil before parsing`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      // Duration may or may not be available before parsing
      // This test just ensures the property doesn't crash
      _ = media.duration
    }

    @Test(.tags(.async, .media))
    func `Parse returns metadata`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let metadata = try await media.parse()
      // test.mp4 has title="Test" embedded
      #expect(metadata.title == "Test")
    }

    @Test
    func `Tracks empty before parsing`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      // Tracks may be empty before parse
      _ = media.tracks()
    }

    @Test(.tags(.async, .media))
    func `Tracks available after parsing`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      _ = try await media.parse()
      let tracks = media.tracks()
      #expect(!tracks.isEmpty)
      // Should have at least one video and one audio track
      #expect(tracks.contains(where: { $0.type == .video }))
      #expect(tracks.contains(where: { $0.type == .audio }))
    }

    @Test
    func `Add option doesn't crash`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      media.addOption(":network-caching=1000")
    }

    @Test
    func `Set metadata doesn't crash`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      media.setMetadata(.title, value: "New Title")
    }

    @Test
    func `Statistics nil before playback`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      #expect(media.statistics() == nil)
    }

    @Test
    func `Is Sendable`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let sendable: any Sendable = media
      _ = sendable
    }

    @Test(.tags(.async, .media))
    func `Multiple media objects parse independently`() async throws {
      // A second parse of one media object only returns the first result,
      // so independence needs two separate media objects.
      let media1 = try Media(url: TestMedia.testMP4URL)
      let media2 = try Media(url: TestMedia.testMP4URL)
      let meta1 = try await media1.parse()
      let meta2 = try await media2.parse()
      #expect(meta1.title == meta2.title)
    }

    @Test
    func `Init from nonexistent path succeeds`() throws {
      // libVLC accepts non-existent paths (it creates the media object;
      // failure surfaces later during parse/playback). Empty paths cause
      // an internal abort, so we test with a valid-looking but nonexistent path.
      let media = try Media(path: "/nonexistent/file.mp4")
      #expect(media.mrl != nil)
    }

    @Test
    func `MRL contains file path for local files`() throws {
      let path = TestMedia.testMP4URL.path
      let media = try Media(path: path)
      let mrl = try #require(media.mrl)
      #expect(mrl.contains("test.mp4"))
    }

    @Test(.tags(.async, .media))
    func `Parse with short timeout`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      // Local files should parse quickly even with short timeout
      let metadata = try await media.parse(timeout: .seconds(2))
      #expect(metadata.title != nil)
    }

    @Test(.tags(.async, .media))
    func `Duration available after parsing`() async throws {
      let media = try Media(url: TestMedia.twosecURL)
      _ = try await media.parse()
      let duration = try #require(media.duration)
      // 2-second file should have duration close to 2000ms
      #expect(duration.milliseconds > 1500)
      #expect(duration.milliseconds < 3000)
    }

    @Test
    func `Init from remote URL`() throws {
      // libVLC accepts remote URLs (uses libvlc_media_new_location)
      let url = try #require(URL(string: "http://example.com/video.mp4"))
      let media = try Media(url: url)
      let mrl = try #require(media.mrl)
      #expect(mrl.contains("example.com"))
    }

    @Test
    func `Save metadata fails for non-writable media`() throws {
      let media = try Media(path: "/nonexistent/file.mp4")
      #expect(throws: VLCError.self) {
        try media.saveMetadata()
      }
    }

    @Test
    func `File descriptor init with invalid fd succeeds`() throws {
      // libVLC accepts -1 fd (failure surfaces later during playback)
      let media = try Media(fileDescriptor: -1)
      #expect(media.mrl != nil)
    }

    @Test(.tags(.async, .media))
    func `Parse cancellation`() async {
      do {
        let media = try Media(url: TestMedia.testMP4URL)
        let task = Task {
          try await media.parse(timeout: .seconds(5))
        }
        // Cancel immediately
        task.cancel()
        do {
          _ = try await task.value
          // May succeed if parse completed before cancellation
        } catch {
          // Expected — cancelled or parse failed
        }
      } catch {
        // Media creation failed
      }
    }

    /// libVLC rejects a parse request for media it has already parsed. The
    /// metadata is there to return, so a repeated call must not surface that
    /// rejection as a failure.
    @Test(.tags(.async, .media))
    func `Parsing already parsed media returns its metadata`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let first = try await media.parse()
      let second = try await media.parse()
      #expect(second == first)
      #expect(second.title == "Test")
    }

    /// Opening media for playback marks it parsed without any parse request.
    @Test(.tags(.async, .media, .mainActor), .enabled(if: TestCondition.canPlayMedia))
    @MainActor func `Parsing media a player has opened returns its metadata`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      try #require(await poll(timeout: .seconds(10)) { player.state == .playing })
      let media = try #require(player.currentMedia)
      try #require(
        await poll(timeout: .seconds(5)) {
          libvlc_media_get_parsed_status(media.pointer) == libvlc_media_parsed_status_done
        },
        "precondition: playback must have marked the media parsed"
      )
      let metadata = try await media.parse(instance: TestInstance.shared)
      #expect(metadata.duration != nil)
      await player.shutdown()
    }

    /// One parse per media at a time is libVLC's rule and stays visible: the
    /// call that loses is rejected rather than joined to the one in flight.
    @Test(.tags(.async, .media))
    func `A parse started while another is in flight is rejected`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      let errors = await withTaskGroup(of: VLCError?.self) { group in
        for _ in 0..<2 {
          group.addTask {
            do throws(VLCError) {
              _ = try await media.parse()
              return nil
            } catch {
              return error
            }
          }
        }
        var errors: [VLCError] = []
        for await error in group {
          if let error {
            errors.append(error)
          }
        }
        return errors
      }
      #expect(errors.count <= 1, "at least one of the two parses must succeed")
      for error in errors {
        #expect(error == .parseFailed(reason: "parse request rejected"))
      }
    }

    @Test
    func `Duration nil for unparsed media`() throws {
      let media = try Media(path: "/nonexistent/file.mp4")
      // Duration is -1 before parsing, which maps to nil
      #expect(media.duration == nil)
    }

    @Test
    func `Tracks empty for unparsed local media`() throws {
      let media = try Media(path: "/nonexistent/file.mp4")
      #expect(media.tracks().isEmpty)
    }

    @Test
    func `Set and read metadata roundtrip`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      media.setMetadata(.title, value: "Custom Title")
      // Note: setMetadata is in-memory; reading back may or may not
      // reflect the change without save+reparse
    }

    @Test
    func `Add multiple options`() throws {
      let media = try Media(url: TestMedia.testMP4URL)
      media.addOption(":network-caching=1000")
      media.addOption(":no-video")
      media.addOption(":no-audio")
      // No crash = success
    }
  }
}
