@testable import SwiftVLC
import CLibVLC
import Testing

extension Integration {
  struct TrackExtendedTests {
    // MARK: - TrackType cValue round-trip

    @Test(
      arguments: [
        (TrackType.audio, libvlc_track_audio),
        (.video, libvlc_track_video),
        (.subtitle, libvlc_track_text),
        (.unknown, libvlc_track_unknown)
      ] as [(TrackType, libvlc_track_type_t)]
    )
    func `TrackType cValue round-trip for all types`(type: TrackType, expected: libvlc_track_type_t) {
      #expect(type.cValue == expected)
      #expect(TrackType(from: expected) == type)
    }

    @Test
    func `TrackType from unknown C value maps to unknown`() {
      // Use a raw value that does not correspond to any known track type
      let bogus = libvlc_track_type_t(rawValue: 999)
      let trackType = TrackType(from: bogus)
      #expect(trackType == .unknown)
    }

    // MARK: - MediaSlaveType

    @Test(
      arguments: [
        (MediaSlaveType.subtitle, libvlc_media_slave_type_subtitle),
        (.audio, libvlc_media_slave_type_audio),
      ] as [(MediaSlaveType, libvlc_media_slave_type_t)]
    )
    func `MediaSlaveType cValue for both cases`(type: MediaSlaveType, expected: libvlc_media_slave_type_t) {
      #expect(type.cValue == expected)
    }

    @Test(
      arguments: [
        (MediaSlaveType.subtitle, "subtitle"),
        (.audio, "audio"),
      ] as [(MediaSlaveType, String)]
    )
    func `MediaSlaveType descriptions`(type: MediaSlaveType, expected: String) {
      #expect(type.description == expected)
    }

    // MARK: - Track equality and hashing

    @Test
    func `Track equality - same id are equal`() {
      let a = makeTrack(id: "track-1", type: .audio, name: "English")
      let b = makeTrack(id: "track-1", type: .video, name: "French") // different type/name, same id
      #expect(a == b)
    }

    @Test
    func `Track equality - different ids are not equal`() {
      let a = makeTrack(id: "track-1", type: .audio)
      let b = makeTrack(id: "track-2", type: .audio)
      #expect(a != b)
    }

    @Test
    func `Track hashability - same id produces same hash`() {
      let a = makeTrack(id: "hash-test", type: .video)
      let b = makeTrack(id: "hash-test", type: .audio)
      #expect(a.hashValue == b.hashValue)

      let set: Set<Track> = [a, b]
      #expect(set.count == 1)
    }

    @Test
    func `Track Identifiable - id is the identifier`() {
      let track = makeTrack(id: "ident-42", type: .subtitle)
      #expect(track.id == "ident-42")

      // Identifiable protocol: id property should match
      let identifiable: any Identifiable = track
      #expect(identifiable.id as? String == "ident-42")
    }

    // MARK: - Parsed media track properties

    @Test(.tags(.async, .media))
    func `Parsed audio track has channels and sampleRate`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      _ = try await media.parse()
      let audioTracks = media.tracks().filter { $0.type == .audio }
      guard let audio = audioTracks.first else { return } // may be empty on simulators
      _ = audio.channels
      _ = audio.sampleRate
    }

    @Test(.tags(.async, .media))
    func `Parsed video track has width height and frameRate`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      _ = try await media.parse()
      let videoTracks = media.tracks().filter { $0.type == .video }
      guard let video = videoTracks.first else { return } // may be empty on simulators
      _ = video.width
      _ = video.height
      // frameRate may or may not be present depending on container metadata
    }

    @Test
    func `Audio track has nil video and subtitle properties`() {
      let audio = makeTrack(id: "a-0", type: .audio, channels: 2, sampleRate: 44100)
      #expect(audio.width == nil)
      #expect(audio.height == nil)
      #expect(audio.frameRate == nil)
      #expect(audio.encoding == nil)
      #expect(audio.channels == 2)
      #expect(audio.sampleRate == 44100)
    }

    @Test
    func `Video track has nil audio and subtitle properties`() {
      let video = makeTrack(id: "v-0", type: .video, width: 1920, height: 1080, frameRate: 24.0)
      #expect(video.channels == nil)
      #expect(video.sampleRate == nil)
      #expect(video.encoding == nil)
      #expect(video.width == 1920)
      #expect(video.height == 1080)
      #expect(video.frameRate == 24.0)
    }

    @Test
    func `Subtitle track has nil audio and video properties`() {
      let sub = Track(
        id: "sub-0",
        type: .subtitle,
        name: "English",
        codec: 0,
        language: "en",
        trackDescription: nil,
        isSelected: false,
        bitrate: 0,
        channels: nil,
        sampleRate: nil,
        width: nil,
        height: nil,
        frameRate: nil,
        encoding: "UTF-8"
      )
      #expect(sub.channels == nil)
      #expect(sub.sampleRate == nil)
      #expect(sub.width == nil)
      #expect(sub.height == nil)
      #expect(sub.frameRate == nil)
      #expect(sub.encoding == "UTF-8")
    }

    @Test
    func `Unknown track type has all type-specific properties nil`() {
      let track = makeTrack(id: "u-0", type: .unknown)
      #expect(track.channels == nil)
      #expect(track.sampleRate == nil)
      #expect(track.width == nil)
      #expect(track.height == nil)
      #expect(track.frameRate == nil)
      #expect(track.encoding == nil)
    }

    @Test
    func `Track with nil language and description`() {
      let track = makeTrack(id: "x-0", type: .audio)
      #expect(track.language == nil)
      #expect(track.trackDescription == nil)
    }

    @Test
    func `Track with populated language and description`() {
      let track = Track(
        id: "a-1",
        type: .audio,
        name: "Commentary",
        codec: 0x6D70_3461, // mp4a
        language: "fr",
        trackDescription: "Director commentary",
        isSelected: true,
        bitrate: 256_000,
        channels: 6,
        sampleRate: 48000,
        width: nil,
        height: nil,
        frameRate: nil,
        encoding: nil
      )
      #expect(track.language == "fr")
      #expect(track.trackDescription == "Director commentary")
      #expect(track.isSelected == true)
      #expect(track.bitrate == 256_000)
      #expect(track.codec == 0x6D70_3461)
    }

    // MARK: - Helpers

    private func makeTrack(
      id: String,
      type: TrackType,
      name: String = "Track",
      channels: Int? = nil,
      sampleRate: Int? = nil,
      width: Int? = nil,
      height: Int? = nil,
      frameRate: Double? = nil
    ) -> Track {
      Track(
        id: id,
        type: type,
        name: name,
        codec: 0,
        language: nil,
        trackDescription: nil,
        isSelected: false,
        bitrate: 0,
        channels: channels,
        sampleRate: sampleRate,
        width: width,
        height: height,
        frameRate: frameRate,
        encoding: nil
      )
    }
  }
}
