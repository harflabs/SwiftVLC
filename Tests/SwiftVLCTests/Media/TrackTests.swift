@testable import SwiftVLC
import CLibVLC
import Testing

@Suite("Track", .tags(.logic))
struct TrackTests {
  @Test(
    "TrackType descriptions",
    arguments: [
      (TrackType.audio, "audio"),
      (.video, "video"),
      (.subtitle, "subtitle"),
      (.unknown, "unknown")
    ] as [(TrackType, String)]
  )
  func trackTypeDescriptions(type: TrackType, expected: String) {
    #expect(type.description == expected)
  }

  @Test("Equality by id")
  func equalityById() {
    let a = makeTrack(id: "audio-0", type: .audio, name: "English")
    let b = makeTrack(id: "audio-0", type: .audio, name: "French")
    #expect(a == b) // Equal by id, even though name differs
  }

  @Test("Hashable by id")
  func hashableById() {
    let a = makeTrack(id: "video-0", type: .video)
    let b = makeTrack(id: "video-0", type: .video)
    let set: Set<Track> = [a, b]
    #expect(set.count == 1)
  }

  @Test("Parsed audio track properties", .tags(.integration, .async, .media))
  func parsedAudioTrackProperties() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let tracks = media.tracks().filter { $0.type == .audio }
    let audio = try #require(tracks.first)
    #expect(audio.type == .audio)
    #expect(audio.channels != nil)
    #expect(audio.sampleRate != nil)
    #expect(audio.width == nil) // Not a video track
    #expect(audio.height == nil)
  }

  @Test("Parsed video track properties", .tags(.integration, .async, .media))
  func parsedVideoTrackProperties() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let tracks = media.tracks().filter { $0.type == .video }
    let video = try #require(tracks.first)
    #expect(video.type == .video)
    #expect(video.width == 64)
    #expect(video.height == 64)
    #expect(video.channels == nil) // Not an audio track
    #expect(video.sampleRate == nil)
  }

  @Test(
    "MediaSlaveType descriptions",
    arguments: [
      (MediaSlaveType.subtitle, "subtitle"),
      (.audio, "audio")
    ] as [(MediaSlaveType, String)]
  )
  func mediaSlaveTypeDescriptions(type: MediaSlaveType, expected: String) {
    #expect(type.description == expected)
  }

  @Test("Nil cross-type properties")
  func nilCrossTypeProperties() {
    let audioTrack = makeTrack(id: "a-0", type: .audio, channels: 2, sampleRate: 44100)
    #expect(audioTrack.width == nil)
    #expect(audioTrack.height == nil)
    #expect(audioTrack.frameRate == nil)
    #expect(audioTrack.encoding == nil)

    let videoTrack = makeTrack(id: "v-0", type: .video, width: 1920, height: 1080)
    #expect(videoTrack.channels == nil)
    #expect(videoTrack.sampleRate == nil)
    #expect(videoTrack.encoding == nil)
  }

  @Test("Track is Identifiable")
  func trackIsIdentifiable() {
    let track = makeTrack(id: "sub-0", type: .subtitle)
    #expect(track.id == "sub-0")
  }

  @Test("Track is Sendable")
  func trackIsSendable() {
    let track = makeTrack(id: "a-0", type: .audio)
    let sendable: any Sendable = track
    _ = sendable
  }

  @Test("TrackType Hashable")
  func trackTypeHashable() {
    let set: Set<TrackType> = [.audio, .video, .subtitle, .unknown, .audio]
    #expect(set.count == 4)
  }

  @Test(
    "TrackType cValue round-trip",
    arguments: [
      (TrackType.audio, libvlc_track_audio),
      (.video, libvlc_track_video),
      (.subtitle, libvlc_track_text),
      (.unknown, libvlc_track_unknown),
    ] as [(TrackType, libvlc_track_type_t)]
  )
  func trackTypeCValueRoundTrip(type: TrackType, expected: libvlc_track_type_t) {
    #expect(type.cValue == expected)
    #expect(TrackType(from: expected) == type)
  }

  @Test(
    "MediaSlaveType cValue",
    arguments: [
      (MediaSlaveType.subtitle, libvlc_media_slave_type_subtitle),
      (.audio, libvlc_media_slave_type_audio),
    ] as [(MediaSlaveType, libvlc_media_slave_type_t)]
  )
  func mediaSlaveTypeCValue(type: MediaSlaveType, expected: libvlc_media_slave_type_t) {
    #expect(type.cValue == expected)
  }

  @Test("Track with all properties")
  func trackWithAllProperties() {
    let track = Track(
      id: "sub-0",
      type: .subtitle,
      name: "English",
      codec: 0x7478_7433, // txt3
      language: "en",
      trackDescription: "English subtitles",
      isSelected: true,
      bitrate: 0,
      channels: nil,
      sampleRate: nil,
      width: nil,
      height: nil,
      frameRate: nil,
      encoding: "UTF-8"
    )
    #expect(track.encoding == "UTF-8")
    #expect(track.language == "en")
    #expect(track.trackDescription == "English subtitles")
    #expect(track.isSelected == true)
  }

  @Test("Video track with frame rate")
  func videoTrackWithFrameRate() {
    let track = Track(
      id: "v-0",
      type: .video,
      name: "Video",
      codec: 0,
      language: nil,
      trackDescription: nil,
      isSelected: false,
      bitrate: 5_000_000,
      channels: nil,
      sampleRate: nil,
      width: 1920,
      height: 1080,
      frameRate: 29.97,
      encoding: nil
    )
    #expect(track.frameRate != nil)
    #expect(track.bitrate == 5_000_000)
  }

  @Test("Track with language and description")
  func trackWithLanguageAndDescription() {
    let track = Track(
      id: "a-0",
      type: .audio,
      name: "English Audio",
      codec: 0,
      language: "en",
      trackDescription: "2ch stereo",
      isSelected: true,
      bitrate: 128_000,
      channels: 2,
      sampleRate: 44100,
      width: nil,
      height: nil,
      frameRate: nil,
      encoding: nil
    )
    #expect(track.language == "en")
    #expect(track.trackDescription == "2ch stereo")
    #expect(track.isSelected == true)
    #expect(track.bitrate == 128_000)
  }

  @Test("Subtitle track with encoding")
  func subtitleTrackWithEncoding() {
    let track = Track(
      id: "sub-0",
      type: .subtitle,
      name: "English",
      codec: 0,
      language: "en",
      trackDescription: "SRT subtitles",
      isSelected: false,
      bitrate: 0,
      channels: nil,
      sampleRate: nil,
      width: nil,
      height: nil,
      frameRate: nil,
      encoding: "UTF-8"
    )
    #expect(track.encoding == "UTF-8")
    #expect(track.language == "en")
    #expect(track.channels == nil)
    #expect(track.width == nil)
  }

  @Test("Parsed tracks from media have properties", .tags(.integration, .async, .media))
  func parsedTracksHaveProperties() async throws {
    let media = try Media(url: TestMedia.testMP4URL)
    _ = try await media.parse()
    let tracks = media.tracks()
    #expect(!tracks.isEmpty)
    for track in tracks {
      #expect(!track.id.isEmpty)
      #expect(!track.name.isEmpty)
      // All tracks should have a valid type
      switch track.type {
      case .audio, .video, .subtitle, .unknown:
        break // All valid
      }
    }
  }

  // MARK: - Helpers

  private func makeTrack(
    id: String,
    type: TrackType,
    name: String = "Track",
    channels: Int? = nil,
    sampleRate: Int? = nil,
    width: Int? = nil,
    height: Int? = nil
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
      frameRate: nil,
      encoding: nil
    )
  }
}
